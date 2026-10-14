# DMG window layout (D17)

This is the contract between the art (designer) and the release pipeline (R1, `scripts/release.sh`). All numbers are in **points**, measured from the **top-left of the window's content area** (below the title bar). Preview: `docs/design/dmg-d17.png`.

## Files

| File | What it is |
|---|---|
| `background.png` | 660 × 420 px, 72 dpi (@1x) |
| `background@2x.png` | 1320 × 840 px, 144 dpi (@2x) |
| `ZeusVolume.icns` | Volume icon: the app icon, masked to the macOS squircle (volumes aren't masked by the system), with a pixel drive badge. 16–1024 px, 10 entries. |

Combine the two backgrounds into one HiDPI TIFF (checked: 2 directories, 72 and 144 dpi):

```sh
tiffutil -cathidpicheck scripts/dmg/art/background.png scripts/dmg/art/background@2x.png -out build/release/background.tiff
```

## Window

| Setting | Value |
|---|---|
| Content size | **660 × 420** (exactly the background) |
| View | icon view; no toolbar, sidebar, path bar, status bar or tab bar |
| Icon size | **128** |
| Text size | **12**, labels at the **bottom** |
| Arrange by | none (fixed positions), no icon previews |

## Icon centres

| Item | Centre (x, y) | Icon box (128 × 128) | Label lands on |
|---|---|---|---|
| `Zeus.app` | **(166, 200)** | x 102–230, y 136–264 | the left plinth's face, y ≈ 262–296 |
| `Applications` (symlink to `/Applications`) | **(494, 200)** | x 430–558, y 136–264 | the right plinth's face |

- The two slots are mirror-symmetric about x = 330.
- The bolt arrow runs between the icon boxes at y ≈ 194–214, and Zeus stands under it. Nothing else should go in the window: no hidden files visible, no `.background` folder, no `.VolumeIcon.icns`. Hide them, as dmgbuild does by default.

**Label legibility.** Finder draws icon labels black in light mode and white in dark mode, on top of the background image. Each label sits on a plinth face coloured `#6E7496`, which has a relative luminance of about 0.18. That gives about 4.6:1 contrast against both black and white text, so the window reads in either appearance. Keep the text size at 12 so a label stays on its plinth face.

## dmgbuild settings

dmgbuild's `icon_locations` and the `.DS_Store` `Iloc` record are icon **centres**, which is what the table above gives.

```python
# settings.py (excerpt), all values from this file
window_rect = ((200, 120), (660, 420))     # content size must come out at 660 × 420; see the note below
icon_size = 128
text_size = 12
label_pos = 'bottom'
default_view = 'icon-view'
arrange_by = None
show_icon_preview = False
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
background = 'build/release/background.tiff'
icon = 'scripts/dmg/art/ZeusVolume.icns'
files = ['build/release/Zeus.app']
symlinks = {'Applications': '/Applications'}
icon_locations = {'Zeus.app': (166, 200), 'Applications': (494, 200)}
```

**Note for R1.** Verify once, by mounting, that the window's *content* area is exactly 660 × 420: the background shouldn't tile or crop, and there should be no scroll bars. Some Finder versions count the title bar in the window bounds. If the content comes out short, grow the height in `window_rect` by the difference, and leave the art and the centres as they are.

## Regenerating

The art is rendered from code (`Packages/ZeusKit/Sources/zeus-sprites/DMGArt.swift`). Zeus comes from his sprite file, and the text is set in the bundled Departure Mono. The output is byte-for-byte reproducible.

The app icon comes first, since the volume icon and the preview are made from it (F11: full-bleed art that macOS masks itself).

```sh
scripts/build.sh    # or: swift build in Packages/ZeusKit
build/ZeusKit/debug/zeus-sprites appicon Zeus/Resources/Assets.xcassets/AppIcon.appiconset
build/ZeusKit/debug/zeus-sprites dmg scripts/dmg/art \
    --app-icon Zeus/Resources/Assets.xcassets/AppIcon.appiconset \
    --preview docs/design/dmg-d17.png
```

The geometry constants live in `DMGLayout` in that file. If you change them, change this table too.
