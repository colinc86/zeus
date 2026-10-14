# Building a Zeus release

Run from the checkout or worktree root on macOS with Xcode, XcodeGen and Python 3:

```sh
scripts/release.sh
```

This runs `scripts/test.sh`, recreates `build/release/`, builds Release for **arm64
and x86_64**, and creates `build/release/Zeus-<version>.dmg`. Use
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
`SHA256SUMS` is calculated **after** stapling. Share the DMG only when its status
says signed/notarized/stapled and the final D17 art is installed. No upload or
publication service is part of this pipeline.
