# Building a Zeus release

Run from the checkout or worktree root on macOS with Xcode, XcodeGen and Python 3:

```sh
scripts/live.sh
scripts/release.sh
```

Before every release, run the **full** live gate on the revision being packaged:
`scripts/live.sh`. It builds the app and native test bundle once (`build.sh --for-testing`), then
serially verifies app control,
learnings/Skip, managed and own-session completion, native screen variants,
Connect-your-own delivery, and real bridge E2E. Every native CLI uses its own
private tmux socket, disposable HOME/config, scratch folder and localhost model.
It never uses your agent credentials or default tmux server. Missing CLIs print
an explicit SKIP row; review those omissions before releasing. Any failed or
timed-out probe fails the gate; there are no automatic retries.

The final table and `summary.json` are under `build/live/<UTC timestamp>/`, with
per-probe logs, proof and native test result bundles. Recorded fixtures remain
unchanged unless you explicitly use `--record`. Host source fingerprints cache
headless builds across agent rows; the app is not rebuilt by each probe.

```sh
scripts/live.sh --quick                    # smoke: shortest scenario per probe
scripts/live.sh --agents claude,codex      # explicit agent subset
scripts/live.sh --only sa3,sa4,cy1,e2e      # selected probes
scripts/live.sh --only sa4 --record        # explicitly replace recorded evidence
python3 -B scripts/test_live_gate.py        # offline gate/helper regressions
```

`--quick` omits long/secondary cases: LV1's Skip transports; SA1's TTL, questions,
permissions and own stale observation; SA2's queue/draft cases; SA3/SA4's second
turn and Claude failure; PC1's scheduled/working/permission/update variants.
CY1 and E2E keep their complete scenarios. Quick smoke does **not** replace the
full release gate. `--record --quick` is rejected so reduced coverage cannot
replace a full recorded fixture. Recording PC1 Claude intentionally enables the
native updater only for its disposable copy, as that probe requires.

LG2 suite reliability baseline (code revision `72653c8`, 2026-10-15): three
consecutive quiet `scripts/test.sh` runs and a fourth alongside a cold build in a
separate worktree passed with identical counts: 1,002 app tests (978 passed,
24 normal opt-in skips), 249 package tests, and 16 release + 10 live-gate offline
fixtures. Both builds passed with no new warnings. See
[the saturation audit](audit/lg2-suite-saturation.md) for attribution, fixes,
timings and logs. Ordinary fixtures default to static native/SwiftUI hosts and
serialize real process fixtures across suites; motion tests explicitly opt in.
These ordinary-suite passes do not replace the full native live gate above.

This runs `scripts/test.sh`, recreates `build/release/`, builds Release for **arm64
and x86_64**, and creates `build/release/Zeus-<version>.dmg` and the Sparkle
update archive `Zeus-<version>.zip`. Without `--publish`, the script stops at local
artifacts: it never creates tags, GitHub releases, commits or pushes. Use
`--skip-tests` only when the same revision has already passed tests. Debug builds
remain ad-hoc and retain the usual build directories.

Release requires a `Developer ID Application` certificate and its private key in
your keychain. Copy `scripts/release.local.env.example` to `scripts/release.local.env`
(git-ignored) and set `ZEUS_SIGN_IDENTITY`, `ZEUS_TEAM_ID` and `ZEUS_NOTARY_PROFILE`,
or export them in the environment. The Release embed step signs `zeus-mcp`
with hardened runtime and a secure timestamp **before** Xcode seals the app.
The app has hardened runtime too. No new entitlements or sandbox are required.
Release disables Xcode's base-entitlement injection so it cannot acquire the
`com.apple.security.get-task-allow` debugger entitlement that notarization rejects.
The pipeline verifies both architectures, authority, team, runtime and timestamp
on the app and bridge, rejects debugger entitlements, then verifies the actual
packaged copies after mounting.

## Versions and Sparkle signing

Set `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in `project.yml` before
releasing. They are the only source of the version and build number. Commit those
changes before publishing from clean main. Use versions
like `0.1.4` or `0.1.5-beta.1` and positive integer build numbers. Sparkle compares
the build number, so increase it for **every** release, including betas. The script
refuses a build that does not strictly exceed the highest build in `appcast.xml`.
An exact existing item is accepted only for an idempotent publish resume.

Build once with Sparkle integrated so Xcode resolves its tools. They are under this
checkout's `build/SourcePackages/artifacts/` or the Release SourcePackages directory,
in `Sparkle/bin`. The release script discovers `generate_keys` and `sign_update`
there; it never borrows another app's artifacts or tools from global DerivedData.
Create the named signing account once, interactively:

```sh
path/to/Sparkle/bin/generate_keys --account zeus
path/to/Sparkle/bin/generate_keys --account zeus -p
```

The private EdDSA key stays in the Keychain. Do not export it or put it in an
environment variable, tracked file or release artifact. Put the printed **public**
key in the app's `SUPublicEDKey` setting and rebuild. The pipeline checks the built
app's key against `generate_keys --account zeus -p` and checks its `SUFeedURL`.
A missing account, placeholder/mismatched public key or missing tools fails with
setup instructions. No key is created automatically.

After app stapling and DMG verification, `ditto -c -k --keepParent` archives the
final app and `sign_update --account zeus` signs that ZIP. The feed carries its
EdDSA signature and actual byte length. [Sparkle's signing and publishing guide](https://sparkle-project.org/documentation/)

## Publishing and resuming

Publishing is explicitly opt-in and requires clean `main`, `origin` pointing at
the public `colinc86/zeus` repository, authenticated `gh`, and notarized artifacts.
Keep the Markdown notes outside `build/release/`, which a new build recreates, and
outside tracked/untracked source files so `main` stays clean. For example:

```sh
mkdir -p build
# Write the user-facing release notes to build/notes.md, then:
scripts/release.sh --publish build/notes.md
```

The script fetches `origin/main` and refuses to publish from behind it. It tags
the packaged source revision as `v<version>`, pushes that tag, creates the GitHub
release with the DMG and ZIP, and renders the Markdown through GitHub's HTML API.
It verifies uploaded bytes against local SHA-256 values, writes the ZIP's public
`browser_download_url` into `appcast.xml`, then commits and pushes **only** the
appcast on main. Public updates require no GitHub integration token in Zeus.
`SUFeedURL` is `https://raw.githubusercontent.com/colinc86/zeus/main/appcast.xml`.

Versions ending in `-beta.N` become GitHub prereleases. As in the reference Gloss
flow, they are listed in the same appcast without a separate Sparkle channel, so
installed copies checking that feed can be offered them. Release notes appear as
HTML in Sparkle and as Markdown on GitHub. The minimum system version is 26.0.

If publication fails after tagging, keep `build/release/` and the original notes:

```sh
scripts/release.sh --publish build/notes.md --resume
```

Resume never rebuilds, notarizes or signs again. `publish.json` remembers the
source revision, version/build, signature and archive hashes. Existing tags and
releases must match; missing assets are uploaded without overwriting existing
assets. Existing uploaded bytes and the appcast item are verified. The appcast
write is atomic and an identical rerun leaves it byte-for-byte unchanged. Resume
also finishes a committed appcast whose push failed, or an appcast file left
uncommitted by an interrupted commit. It refuses changed artifacts, changed
notes, unrelated source changes or a tag pointing elsewhere. If main advanced
remotely, update it first; unrelated code changes require a new release build.
Do not delete the saved artifacts until publication succeeds.

`--publish --no-notarize` and `--resume` without `--publish` are rejected. A local
signed build cannot be promoted to a shareable release without rebuilding through
the notarized path. `python3 -B scripts/test_release.py` exercises appcast ordering,
idempotence, version checks, public-key checks and interrupted publication using
disposable files and mocked GitHub/git commands; it never contacts GitHub or tags
the repository. These tests also run in `scripts/test.sh`.

## Notarization

The script passes **only** the notary profile name (`ZEUS_NOTARY_PROFILE`, default `zeus-notary`) to `notarytool`; it never
extracts credentials or accepts passwords in arguments. If the profile is missing,
configure it interactively:

```sh
xcrun notarytool store-credentials zeus-notary --apple-id YOUR_APPLE_ID --team-id YOUR_TEAM_ID
```

The normal path submits a ZIP of the signed app, waits for `Accepted`, and staples
and validates the app. It then builds the DMG containing that stapled app, signs
the DMG, submits it to Apple, and staples and validates it. Stapling the app before
packaging makes the drag-installed copy carry its own ticket for offline use.
These are two submissions using Apple's supported archive formats and named
Keychain profile. [Apple's notarization workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow)

Use this for local packaging without any submission or Keychain-profile lookup:

```sh
scripts/release.sh --no-notarize
```

This still requires Developer ID signing; it skips notarization, stapling and
Gatekeeper assessments. It is explicitly marked **signed local build only** in
`build/release/RELEASE-STATUS.txt`. It is not the shareable release.

## D17 art and layout

`scripts/dmg/layout.json` implements D17's [LAYOUT.md](../scripts/dmg/art/LAYOUT.md):
660×420 content, icon centres (166, 200) / (494, 200), 128-point icons and 12-point
bottom labels. It uses `background.png`, `background@2x.png`, and `ZeusVolume.icns`
from `scripts/dmg/art/`. For another location/configuration:

```sh
scripts/release.sh --art-dir /path/to/art --layout /path/to/layout.json
```

Absent art produces a clearly labelled temporary background and uses the app icon
as the volume icon; generated assets stay in `build/release/dmg/`. Partial art or
an existing `LAYOUT.md` with missing configured assets fails instead of silently
substituting a placeholder. Placeholder output is flagged in `RELEASE-STATUS.txt`.
**Replace it before sharing.**

The background must match `content_size` at 1x and 2x (currently
660×420 / 1320×840). Both images become one Retina TIFF through
`tiffutil -cathidpicheck`. The DMG contains Zeus.app, an Applications symlink, a
hidden `.background`, and the volume icon. Pinned `dmgbuild` 1.6.7 writes
`.DS_Store` directly: fixed icon positions, no toolbar/sidebar, icon view, no
automatic arrangement. There is no Finder AppleScript or Automation permission.
Dependencies live only in the git-ignored `build/dmg-venv` and never ship in the app.
[dmgbuild settings](https://dmgbuild.readthedocs.io/en/v1.6.7/settings.html)

`window_size` is the outer Finder frame, distinct from `content_size`. R1b's mounted
Finder check measured a 32-point title bar: the stored frame is **660×452**, leaving
exactly **660×420** for the background with the specified chrome hidden. The Retina
window capture is 1320×904; its 64-pixel title strip leaves the full 1320×840 image.
The footer and bottom border fit, without cropping, tiling or scroll bars. Change
`title_bar_height` and frame height together if a later Finder changes its geometry;
never resize the art or shift the icon centres to compensate. Check a fresh volume
window under `/Volumes`, since navigating an existing Finder window can retain its
previous geometry/chrome. The build itself remains completely headless.

Nine installer verification tests run on every release, including with
`--skip-tests` (which skips only the app/package tests). They reject wrong versions,
icon coordinates, visible Finder chrome, wrong Applications links/background
aliases, art paths outside the configured directory, cropped content frames and
incorrect label sizes. To run just those:

```sh
build/dmg-venv/bin/python -B scripts/dmg/test_verify.py
```

## Verification and output

The script mounts the compressed, signed UDZO image read-only and reads back its
actual `.DS_Store`, Applications link, background, volume icon and app version.
It checks strict signatures again on the packaged app and bridge, then detaches.
An exit trap detaches on verification errors. It refuses to delete a release
directory whose verification mount is still attached.

For notarized output, the final checks assess the packaged app with `spctl -a -vvv`,
the DMG with the requested `spctl -a -vvv -t install`, and the disk-image signature
with `spctl -a -vvv -t open --context context:primary-signature`. All three must
succeed, and both stapled tickets must validate.

Review `build/release/logs/`: build/signature logs, notarization status and failures,
stapler validation, `layout-verified.json`, and Gatekeeper results. The final
`SHA256SUMS` covers the DMG and ZIP and is calculated **after** stapling. Share the
DMG only when its status says signed/notarized/stapled and the final art is
installed. `signature.txt` and `publish.json` stay in the ignored release directory.
