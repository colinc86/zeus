#!/bin/bash
# Developer ID release. No credential extraction; notarytool uses a named profile.
set -euo pipefail
export PYTHONDONTWRITEBYTECODE=1
cd "$(dirname "$0")/.."
ZEUS_RELEASE_ROOT="$PWD"
RELEASE="$ZEUS_RELEASE_ROOT/build/release"
VENV="$ZEUS_RELEASE_ROOT/build/dmg-venv"
# Signing identity, team and notary profile come from the environment or the git-ignored
# scripts/release.local.env (see scripts/release.local.env.example).
LOCAL_ENV="$ZEUS_RELEASE_ROOT/scripts/release.local.env"
if [ -f "$LOCAL_ENV" ]; then
  # shellcheck source=/dev/null
  . "$LOCAL_ENV"
fi
IDENTITY="${ZEUS_SIGN_IDENTITY:-}"
TEAM="${ZEUS_TEAM_ID:-}"
PROFILE="${ZEUS_NOTARY_PROFILE:-zeus-notary}"
SKIP_TESTS=false
NOTARIZE=true
LAYOUT="$ZEUS_RELEASE_ROOT/scripts/dmg/layout.json"
ART_DIR="$ZEUS_RELEASE_ROOT/scripts/dmg/art"
PUBLISH_NOTES=""
RESUME=false

usage() {
  cat <<'USAGE'
Usage: scripts/release.sh [--skip-tests] [--no-notarize] [--art-dir PATH] [--layout PATH]
                          [--publish NOTES.md [--resume]]
  --skip-tests    Skip scripts/test.sh (tests run by default).
  --no-notarize   Produce signed local artifacts; skip Apple submission/stapling/Gatekeeper.
  --art-dir      D17's background PNGs and volume .icns (default scripts/dmg/art).
  --layout       JSON coordinates and art filenames (default scripts/dmg/layout.json).
  --publish      Publish notarized DMG + Sparkle ZIP, then commit/push appcast.xml on main.
  --resume       Finish an interrupted publish from saved build/release/ artifacts; no rebuild.
Outputs: build/release/Zeus-<version>.dmg and .zip, Zeus.app, SHA256SUMS, verification logs.
Version/build come only from project.yml. Without --publish, no GitHub or git mutations.
The release directory is recreated; the build-only Python venv is cached under build/.
USAGE
}
die() { printf 'Release failed: %s\n' "$*" >&2; exit 1; }
while [ "$#" -gt 0 ]; do
  case "$1" in
    --skip-tests) SKIP_TESTS=true; shift ;;
    --no-notarize) NOTARIZE=false; shift ;;
    --resume) RESUME=true; shift ;;
    --publish)
      [ "$#" -ge 2 ] && [ -n "$2" ] || die '--publish requires a Markdown notes file'
      PUBLISH_NOTES="$2"; shift 2 ;;
    --art-dir|--layout)
      [ "$#" -ge 2 ] || die "$1 requires a path"
      if [ "$1" = --art-dir ]; then ART_DIR="$2"; else LAYOUT="$2"; fi
      shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; die "Unknown option: $1" ;;
  esac
done
command -v python3 >/dev/null || die 'Missing build tool: python3'
VERSION=$(python3 scripts/release_support.py version --field version)
BUILD_NUMBER=$(python3 scripts/release_support.py version --field build)
if "$RESUME" && [ -z "$PUBLISH_NOTES" ]; then die '--resume requires --publish NOTES.md'; fi
if [ -n "$PUBLISH_NOTES" ]; then
  "$NOTARIZE" || die '--publish cannot be combined with --no-notarize'
  command -v gh >/dev/null || die 'Missing publishing tool: gh'
  if "$RESUME"; then
    python3 scripts/release_support.py publish --notes "$PUBLISH_NOTES" --resume
    exit 0
  fi
  python3 scripts/release_support.py preflight --notes "$PUBLISH_NOTES"
fi
python3 scripts/appcast.py appcast.xml --version "$VERSION" --build "$BUILD_NUMBER" --check-build
[ -n "$IDENTITY" ] && [ -n "$TEAM" ] || die 'Set ZEUS_SIGN_IDENTITY and ZEUS_TEAM_ID (copy scripts/release.local.env.example to scripts/release.local.env).'
for tool in xcodegen xcodebuild xcrun codesign hdiutil tiffutil sips python3; do
  command -v "$tool" >/dev/null || die "Missing build tool: $tool"
done
[ -f "$LAYOUT" ] || die "Layout not found: $LAYOUT"
if mount | grep -Fq " on $RELEASE/mount ("; then
  die "A previous release is mounted at $RELEASE/mount; detach it before rebuilding."
fi
mkdir -p "$ZEUS_RELEASE_ROOT/build"
if ! "$SKIP_TESTS"; then
  echo '==> Tests (build/release-tests.log)'
  scripts/test.sh > "$ZEUS_RELEASE_ROOT/build/release-tests.log" 2>&1 || {
    tail -n 80 "$ZEUS_RELEASE_ROOT/build/release-tests.log" >&2; die 'Tests did not pass.';
  }
fi
rm -rf "$RELEASE"
mkdir -p "$RELEASE/logs" "$RELEASE/mount"
MOUNT="$RELEASE/mount"
MOUNTED=false
cleanup() {
  if "$MOUNTED"; then
    hdiutil detach "$MOUNT" >/dev/null || printf 'Could not detach %s; detach it manually.\n' "$MOUNT" >&2
  fi
}
trap cleanup EXIT

echo '==> Build-only DMG tools (pinned; build/dmg-venv)'
if [ ! -x "$VENV/bin/python" ]; then python3 -m venv "$VENV"; fi
"$VENV/bin/python" -m pip install --disable-pip-version-check -r scripts/dmg/requirements.txt > "$RELEASE/logs/dmg-tools.log" 2>&1 || {
  cat "$RELEASE/logs/dmg-tools.log" >&2; die 'Could not install the pinned DMG build tools.';
}
"$VENV/bin/python" -m pip freeze > "$RELEASE/logs/dmg-tool-versions.txt"
"$VENV/bin/python" -B scripts/dmg/test_verify.py > "$RELEASE/logs/dmg-tests.log" 2>&1 || {
  cat "$RELEASE/logs/dmg-tests.log" >&2; die 'Installer verification tests failed.';
}

echo '==> Clean universal Release build (build/release/logs/build.log)'
xcodegen generate --quiet
xcodebuild -project Zeus.xcodeproj -scheme Zeus -configuration Release \
  -destination 'generic/platform=macOS' \
  -derivedDataPath "$RELEASE/DerivedData" \
  -clonedSourcePackagesDirPath "$RELEASE/SourcePackages" \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$IDENTITY" DEVELOPMENT_TEAM="$TEAM" \
  clean build > "$RELEASE/logs/build.log" 2>&1 || {
  tail -n 100 "$RELEASE/logs/build.log" >&2
  die 'Release build/signing failed. Install the specified Developer ID certificate and private key; Debug remains ad-hoc.'
}
APP="$RELEASE/Zeus.app"
ditto "$RELEASE/DerivedData/Build/Products/Release/Zeus.app" "$APP"
DMG="$RELEASE/Zeus-$VERSION.dmg"

verify_code() {
  local path="$1" label="$2" runtime="$3"
  codesign --verify --deep --strict --verbose=2 "$path" > "$RELEASE/logs/$label-verify.log" 2>&1 || {
    cat "$RELEASE/logs/$label-verify.log" >&2; die "Signature verification failed: $path";
  }
  codesign -dvv "$path" > "$RELEASE/logs/$label-signature.log" 2>&1
  # Identity and team are local signing configuration, not public release output.
  grep -Fq "Authority=$IDENTITY" "$RELEASE/logs/$label-signature.log" || die "Wrong signing authority: $path"
  grep -Fq "TeamIdentifier=$TEAM" "$RELEASE/logs/$label-signature.log" || die "Wrong signing team: $path"
  grep -Eq '^Timestamp=.' "$RELEASE/logs/$label-signature.log" || die "No secure timestamp: $path"
  if "$runtime"; then
    grep -Eq 'flags=.*runtime' "$RELEASE/logs/$label-signature.log" || die "Hardened runtime missing: $path"
    local binary="$path"
    if [ -d "$path" ]; then binary="$path/Contents/MacOS/Zeus"; fi
    for architecture in arm64 x86_64; do
      xcrun lipo "$binary" -verify_arch "$architecture" || die "Missing $architecture architecture: $path"
    done
    codesign -d --entitlements - --xml "$path" > "$RELEASE/logs/$label-entitlements.plist" 2> "$RELEASE/logs/$label-entitlements.log"
    "$VENV/bin/python" -c 'import pathlib,plistlib,sys; p=pathlib.Path(sys.argv[1]); e=plistlib.loads(p.read_bytes()) if p.stat().st_size else {}; sys.exit(bool(e.get("com.apple.security.get-task-allow")))' \
      "$RELEASE/logs/$label-entitlements.plist" || die "Debugger entitlement is forbidden in Release: $path"
  fi
}
echo '==> Verify app and embedded bridge signatures, runtime, timestamps and architectures'
verify_code "$APP" app true
verify_code "$APP/Contents/MacOS/zeus-mcp" bridge true

notarize() {
  local path="$1" label="$2"
  echo "==> Submit $label to Apple (profile: $PROFILE)"
  if ! xcrun notarytool submit "$path" --keychain-profile "$PROFILE" --wait --output-format json \
      > "$RELEASE/logs/$label-notary.json" 2> "$RELEASE/logs/$label-notary-error.log"; then
    cat "$RELEASE/logs/$label-notary-error.log" >&2
    printf 'Configure the profile if missing:\n  xcrun notarytool store-credentials %s --apple-id YOUR_APPLE_ID --team-id %s\n' "$PROFILE" "$TEAM" >&2
    die "Notarization failed; see logs. Use --no-notarize only for signed local builds."
  fi
  if ! "$VENV/bin/python" -c 'import json,sys; r=json.load(open(sys.argv[1])); print("Notary status:",r.get("status")); sys.exit(r.get("status") != "Accepted")' "$RELEASE/logs/$label-notary.json"; then
    local submission
    submission=$("$VENV/bin/python" -c 'import json,sys; print(json.load(open(sys.argv[1]))["id"])' "$RELEASE/logs/$label-notary.json")
    xcrun notarytool log "$submission" --keychain-profile "$PROFILE" "$RELEASE/logs/$label-notary-details.json" || true
    die "Apple did not accept $label; see $RELEASE/logs/$label-notary-details.json"
  fi
}
if "$NOTARIZE"; then
  # Staple the app BEFORE packaging so drag-installed copies also carry an offline ticket.
  ditto -c -k --keepParent "$APP" "$RELEASE/Zeus-notary.zip"
  notarize "$RELEASE/Zeus-notary.zip" app
  xcrun stapler staple "$APP" > "$RELEASE/logs/app-staple.log" 2>&1
  xcrun stapler validate "$APP" >> "$RELEASE/logs/app-staple.log" 2>&1
fi

echo '==> Headless DMG layout and Retina TIFF background'
"$VENV/bin/python" scripts/dmg/build.py --app "$APP" --output "$DMG" \
  --work "$RELEASE/dmg" --layout "$LAYOUT" --art-dir "$ART_DIR" \
  > "$RELEASE/logs/dmg-build.log" 2>&1 || {
  cat "$RELEASE/logs/dmg-build.log" >&2; die 'DMG creation failed.';
}
codesign --force --sign "$IDENTITY" --timestamp "$DMG"
verify_code "$DMG" dmg false
if "$NOTARIZE"; then
  notarize "$DMG" dmg
  xcrun stapler staple "$DMG" > "$RELEASE/logs/dmg-staple.log" 2>&1
  xcrun stapler validate "$DMG" >> "$RELEASE/logs/dmg-staple.log" 2>&1
fi

echo '==> Mount read-only and verify the packaged app and Finder layout'
hdiutil verify "$DMG" > "$RELEASE/logs/dmg-checksum.log" 2>&1
hdiutil attach -readonly -nobrowse -mountpoint "$MOUNT" -plist "$DMG" > "$RELEASE/logs/mount.plist"
MOUNTED=true
"$VENV/bin/python" scripts/dmg/verify.py --mount "$MOUNT" --layout "$RELEASE/dmg/layout-used.json" \
  --version "$VERSION" --build "$BUILD_NUMBER" > "$RELEASE/logs/layout-verified.json"
cat "$RELEASE/logs/layout-verified.json"
verify_code "$MOUNT/Zeus.app" packaged-app true
verify_code "$MOUNT/Zeus.app/Contents/MacOS/zeus-mcp" packaged-bridge true
if "$NOTARIZE"; then
  xcrun stapler validate "$MOUNT/Zeus.app" > "$RELEASE/logs/packaged-app-staple.log" 2>&1
  spctl -a -vvv "$MOUNT/Zeus.app" > "$RELEASE/logs/app-gatekeeper.log" 2>&1 || {
    cat "$RELEASE/logs/app-gatekeeper.log" >&2; die 'Gatekeeper rejected the packaged app.';
  }
  # Check R1's install policy as well as the disk-image primary signature.
  spctl -a -vvv -t install "$DMG" > "$RELEASE/logs/dmg-install-assessment.log" 2>&1 || {
    cat "$RELEASE/logs/dmg-install-assessment.log" >&2; die 'Gatekeeper rejected the DMG install assessment.';
  }
  echo 0 > "$RELEASE/logs/dmg-install-assessment.exit"
  spctl -a -vvv -t open --context context:primary-signature "$DMG" > "$RELEASE/logs/dmg-gatekeeper.log" 2>&1 || {
    cat "$RELEASE/logs/dmg-gatekeeper.log" >&2; die 'Gatekeeper rejected the notarized disk image.';
  }
  cat "$RELEASE/logs/app-gatekeeper.log" "$RELEASE/logs/dmg-gatekeeper.log"
  printf 'Signed, notarized, stapled; packaged app and DMG accepted by Gatekeeper.\n' > "$RELEASE/RELEASE-STATUS.txt"
else
  printf 'SIGNED LOCAL BUILD ONLY: notarization, stapling and Gatekeeper checks skipped (--no-notarize).\n' > "$RELEASE/RELEASE-STATUS.txt"
fi
if "$VENV/bin/python" -c 'import json,sys; sys.exit(not json.load(open(sys.argv[1]))["placeholder"])' "$RELEASE/dmg/layout-used.json"; then
  printf 'PLACEHOLDER DMG ART: replace with D17 artwork and coordinates before sharing.\n' >> "$RELEASE/RELEASE-STATUS.txt"
fi
cat "$RELEASE/RELEASE-STATUS.txt"
hdiutil detach "$MOUNT" >/dev/null
MOUNTED=false
echo '==> Sparkle archive of the verified app'
ditto -c -k --keepParent "$APP" "$RELEASE/Zeus-$VERSION.zip"
(cd "$RELEASE" && shasum -a 256 "Zeus-$VERSION.dmg" "Zeus-$VERSION.zip" > SHA256SUMS)
echo "==> Release ready: $DMG"
echo '==> Verify public Sparkle key and sign ZIP (Keychain account: zeus)'
if "$NOTARIZE"; then
  python3 scripts/release_support.py sign --notarized
else
  python3 scripts/release_support.py sign
fi
if [ -n "$PUBLISH_NOTES" ]; then
  python3 scripts/release_support.py publish --notes "$PUBLISH_NOTES" || {
    printf 'Publishing interrupted. Keep build/release/ and resume with:\n  scripts/release.sh --publish %q --resume\n' "$PUBLISH_NOTES" >&2
    exit 1
  }
else
  echo '==> Local artifacts only; use --publish NOTES.md on clean main to publish a notarized release.'
fi
