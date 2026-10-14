# UP1 native render

`settings-update.png` is an offscreen AppKit `NSHostingView.cacheDisplay` render of the actual
`AssistantSettingsView`, using a disposable preferences suite and fake managed controller.
The folder is deliberately `/FIXTURE/project`; the attach command is fixture text. No screenshot,
screen capture, real tmux server, agent configuration or credentials were used.

It shows the update caption inside the existing status box and its single, primary **Restart** action.
The same native fixture traverses `NSAccessibility`, presses that button, and verifies an `.agentUpdate`
safe-resume request and the thread's waiting caption, with zero ordinary/destructive restart calls.

Regenerate in the appdev worktree:

```sh
TEST_RUNNER_ZEUS_UP1_RENDER="$PWD/build/up1-settings.png" scripts/test.sh
```

Classifier proof uses PC1's unedited native updater frames in `TestFixtures/panes/claude-2.1/`;
the runtime regression uses an in-memory host plus a private state folder and fake clock.
This is not a fresh live CLI updater run or a capture of the human's desktop.
