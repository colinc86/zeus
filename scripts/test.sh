#!/usr/bin/env bash
# Runs all tests. This is the team's definition of "tests pass".
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ "${ZEUS_TMUX_HYGIENE_ACTIVE:-0}" != "1" ]]; then
  exec python3 -B scripts/tmux_hygiene.py bash "scripts/test.sh" "$@"
fi
ROOT="$PWD"

# Scratch UserDefaults suites live in a folder deleted after the run (Zeus/App/Tests/TestDefaults.swift).
DEFAULTS_DIR="$(mktemp -d "${TMPDIR:-/tmp}/zeus-test-defaults.XXXXXX")"
export TEST_RUNNER_ZEUS_TEST_DEFAULTS_DIR="$DEFAULTS_DIR"
# The run must not add test plists to the real ~/Library/Preferences (cfprefsd ignores HOME).
# Only names are read; nothing there is changed.
PREFS="$(python3 -c 'import os, pwd; print(pwd.getpwuid(os.getuid()).pw_dir)')/Library/Preferences"
test_plists() {
  { ls "$PREFS" 2>/dev/null || true; } | grep -E -i 'zeus|-[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.plist$' | grep -v '^com\.' | sort || true
}
PREFS_BEFORE="$DEFAULTS_DIR/.preferences-before"
test_plists > "$PREFS_BEFORE"
preferences_leak_check() {
  local status=$? leaked
  echo "==> Preferences leak check"
  sleep 2 # cfprefsd writes asynchronously.
  leaked="$(test_plists | comm -13 "$PREFS_BEFORE" -)"
  if [[ -n "$leaked" ]]; then
    echo "error: the run left $(wc -l <<< "$leaked" | tr -d ' ') new plist(s) in $PREFS; use TestDefaults.suite(_:)." >&2
    head -20 <<< "$leaked" >&2
    status=1
  else
    echo "No new test plists in ~/Library/Preferences ($(find "$DEFAULTS_DIR" -name '*.plist' | wc -l | tr -d ' ') scratch suites cleaned up)."
  fi
  rm -rf "$DEFAULTS_DIR"
  exit "$status"
}
trap preferences_leak_check EXIT

python3 -B scripts/test_tmux_hygiene.py

echo "==> Release/appcast tests (offline fixtures)"
python3 -B scripts/test_release.py

echo "==> Live-gate tests (offline fixtures)"
python3 -B scripts/test_live_gate.py

echo "==> ZeusKit tests"
swift test --package-path Packages/ZeusKit --scratch-path "$ROOT/build/ZeusKit"

if [[ -f project.yml ]] && grep -q "ZeusTests" project.yml; then
  echo "==> Zeus app tests"
  xcodegen generate --quiet
  xcodebuild -project Zeus.xcodeproj -scheme Zeus -configuration Debug -destination 'platform=macOS' \
    -derivedDataPath "$ROOT/build/DerivedData" \
    -clonedSourcePackagesDirPath "$ROOT/build/SourcePackages" \
    test 2>&1 | grep -E "Test run with|error:|\*\* TEST (SUCCEEDED|FAILED)"
fi
