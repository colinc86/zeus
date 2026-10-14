# A11 Settings window evidence

These are offscreen, in-process native Settings renders, with an isolated preferences suite, empty disposable history, and a fake password store. No desktop capture, posted global events, real agent configuration or credentials are used.

- `settings-minimum.png`: 572×572 content; every General jump fits above the scroll area.
- `settings-expanded.png`: 800×900 content; controls reflow and the scroll viewport grows without scaling the pixel frames.
- `settings-minimum-history.png`: pressing the History accessibility action brings the history heading and Clear control into view; the jump row stays available.

`SettingsWindowTests` checks every jump's native scroll movement, returning to Updates, resizing, tab switching, size persistence, invalid dimensions, the minimum size, screen bounds and the 2-point grid. Reproduce the renders from the worktree root:

```sh
TEST_RUNNER_ZEUS_A11_RENDER=1 xcodebuild -project Zeus.xcodeproj -scheme Zeus \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$PWD/build/DerivedData" \
  -clonedSourcePackagesDirPath "$PWD/build/SourcePackages" \
  -only-testing:ZeusTests/SettingsWindowTests test
```

Output goes to `build/a11-renders`. For PM live review: open Settings, resize in both dimensions, close/reopen and relaunch Zeus to check size restoration; try all five jumps and keyboard navigation. On current main, Appearance is General's conversation-font section. T1's separate Appearance tab requires reconciling that jump when the branches merge.
