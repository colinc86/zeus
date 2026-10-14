# TB1 app integration renders

These are native `NSHostingView` bitmaps of `ConversationView` in an offscreen,
nonactivating panel with disposable preferences/history and the bundled pixel
font. They use no screen capture, global input, live agents or real tmux server.

- `waiting.png`: avatar question target, first-option focus state, reply chip,
  status strip between thread and composer; narrow layout drops the redundant
  jump words while keeping the sentence clickable and Skip visible.
- `skipped.png`: the same question after Command-Shift-J; options and reply chip
  close, `Skipped` appears beneath the original bubble, strip becomes Idle,
  composer regains focus and no empty user answer is inserted.

Both renders were inspected at native resolution. The native tests also exercise
Command-J through 310 older messages, cycling to the next question's Reply
control, and exact Jump/Skip modifier matching. Focus assertions observe actual
SwiftUI FocusState changes; they do not substitute a requested target for focus.

Regenerate from the appdev worktree after `scripts/build.sh`:

```sh
TEST_RUNNER_ZEUS_TB1_RENDER=1 xcodebuild -project Zeus.xcodeproj -scheme Zeus \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$PWD/build/DerivedData" \
  -clonedSourcePackagesDirPath "$PWD/build/SourcePackages" \
  -only-testing:ZeusTests/StatusStripNativeTests test
```

The test host skips normal font registration, so this fixture registers the font
for its own process. The thread's static Text captions are not exposed by this
offscreen accessibility tree; caption appearance is verified in these bitmaps.
