# AC2 app control evidence

`AppControlModel` implements `AppControlling`; `ShellController.appControl` is the live provider for the PM's `ZeusRuntime(appControl:)` wiring. The model keeps validation and Undo separate from native windows. `CardStore` implements the optional `AppChangeRecording` capability until the shared protocol requirement is promoted.

The PNGs come from in-process, offscreen native views with isolated preferences/history and a fake password store. No screen capture, real agent configuration, network request or installation is involved. `undo.png`, `undone.png` and `show-now.png` use the actual shared quiet-line component. The Settings captures show both control switches and the disabled install switch when the master is off. The test presses Undo through the native accessibility action; the General controls' accessibility names/enabled state are checked without SwiftUI's offscreen scroll adapter, which omits its virtual children.

Reproduce from the worktree root:

```sh
xcodegen generate --quiet
TEST_RUNNER_ZEUS_AC2_RENDER=1 xcodebuild -project Zeus.xcodeproj -scheme Zeus \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$PWD/build/DerivedData" \
  -clonedSourcePackagesDirPath "$PWD/build/SourcePackages" \
  -only-testing:ZeusTests/AppControlModelTests \
  -only-testing:ZeusTests/AppControlUpdateTests \
  -only-testing:ZeusTests/ThreadNoticeTests \
  -only-testing:ZeusTests/UpdaterServiceTests test
```

The update tests use fake drivers only. They cover silent checks, no window activation or automatic-check preference change, a required prior version check, exact native-build matching, cancellation before a cycle starts, stale cancellation, cancellation after download, standard manual UI restoration and Debug unavailability. The production adapter uses Sparkle's existing signature/installation pipeline; this task does not install a Release into the human's running app.

PM visual/integration checklist, after wiring the real provider:

- General: both switches default on; turning off control disables the install switch. Mutating tools and update checks then return `disabled`; state remains readable. Verify labels and caption with keyboard/VoiceOver.
- Ask for a different character/theme/size or appearance patch. One quiet line appears, with no new-message badge or peek; Undo restores the prior changed values and becomes Undone. It sends no reply to the assistant. Relaunch: the text remains; an unavailable in-memory Undo is not offered.
- Create a valid character/theme from the bundled format paths. It is selected and saved in the user library. Undo switches back and keeps its file. A conflicting ID is rejected rather than bypassing Import's Replace confirmation; invalid files use Import's error text.
- Request each corner on the current display, near-active-window, and a clamped point on another display. Unknown window falls back to the main display's right edge. While the composer has focus, move returns `the user is typing`.
- Hide for a duration or until tomorrow. The line offers Show now; clicking it shows Zeus and resolves the action once.
- In an eligible signed Release with a real available update: check reports a version without showing update UI; an explicit install of that checked version downloads/relaunches without a click, after runtime's delivery/blocked guards allow it. Confirm the managed session survives. Debug must report updater unavailable. Real download/relaunch remains a Release review check.
