# S3: live settings resume

These captures use the production managed launch, native conversation discovery, restart controller and tmux delivery in a private socket and disposable HOME/project. All model requests go to a localhost fixture with synthetic credentials. `/FIXTURE` replaces the scratch root. The JSON beside each ANSI capture records the installed CLI, selected permission policy, native-ID continuity and observed instruction forwarding.

Verified:

| Agent | Permission change on resume | Instruction change on resume |
| --- | --- | --- |
| Claude Code 2.1.299 | Ask first → Plan only; native footer shows plan mode | New instructions reach the model's system role with `--system-prompt-snapshot off` |
| Codex 0.162.1 | Workspace write → Read only; native `/status` confirms it | The resumed model retains the original developer instructions; Settings says new instructions apply to the next new conversation |
| OpenCode 1.18.31 | Ask → Deny; native model tool list removes Bash/edit/write and preserves Zeus tools | New instructions reach the model's system role |

Every case resumes the exact same native ID and retains the earlier conversation turn. The fixture sends `S3_RESUME_PROBE` after resume, rather than trusting the launch argument vector. Claude's default snapshot behavior was also reproduced before enabling snapshot-off; merely changing `--append-system-prompt` left the old instructions active. The supported flag is documented in the [Claude CLI reference](https://code.claude.com/docs/en/cli-reference#system-prompt-flags-in-resumed-conversations). Zeus checks the installed CLI's help before using it; unknown/older installations get the next-new-conversation fallback. Codex overrides were checked both before and after the `resume` subcommand, with the same retention result.

The OpenCode policy check compares actual model tool lists before and after resume. If Bash remains available, the fixture requests only a write to its own `s3-policy.txt`; the expected deny policy must prevent that write. No native tool/permission question is accepted automatically. The test human accepts only the disposable Claude folder trust and synthetic API-key setup.

Run from the worktree root:

```sh
xcodegen generate --quiet
TEST_RUNNER_ZEUS_S3_LIVE=1 TEST_RUNNER_ZEUS_S3_RECORD_FIXTURES=1 \
  xcodebuild -project Zeus.xcodeproj -scheme Zeus -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath "$PWD/build/DerivedData" \
  -clonedSourcePackagesDirPath "$PWD/build/SourcePackages" \
  -only-testing:ZeusTests/ManagedSettingsLiveTests test
```

Omit `TEST_RUNNER_ZEUS_S3_RECORD_FIXTURES` to verify without rewriting evidence. Ordinary `scripts/test.sh` skips real CLI launches and runs the deterministic state-machine tests. The helper removes only its private server and verified fixture process lifetimes.

`settings-switch.png` is an offscreen, in-process Settings render using synthetic data (not a desktop screen capture). `LiveManagedSettingsTests` verifies Switch Now/Later labels and routes Escape only to that fixture window. The PM's live check should also confirm Later receives initial keyboard focus.

PM live checks:

- With a running, idle assistant, change a non-Unrestricted permission mode. It resumes automatically; earlier conversation turns remain.
- Edit Claude/OpenCode Instructions repeatedly. One resume follows the typing pause or leaving the field. Codex shows the next-new-conversation caption and does not restart solely for Instructions.
- While the assistant works, waits on a native prompt, has a Terminal draft, or has delivery/answer verification in flight, edit settings. The pending note remains and no pane is stopped; the latest edit applies once it is safely idle and empty.
- Change Agent/Folder: Later is focused; Escape leaves the existing conversation running with the restart/switch affordance. Switch Now waits for a safe moment and starts one new conversation. Permission/instruction edits replace a confirmed waiting switch without another confirmation.
- Revert pending edits to the applied values: the pending note clears. Start when Zeus opens alone causes no restart. Unrestricted still requires its confirmation.
