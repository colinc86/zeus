# Managed prompt-answer proof

`permission_model.py` serves deterministic Anthropic/OpenAI-compatible responses
on localhost. It emits one harmless shell tool request per `P1_PERMISSION_…`
fixture prompt: writing `P1_PROCEEDED` to `p1-approval.txt` in the scratch project.
It never executes the command or accepts a permission itself. The test clicks the
listed choice through `ManagedPromptAnswering` on the actual runtime.

```sh
python3 -u TestFixtures/models/permission_model.py
# In another shell, use the printed localhost URL:
xcodegen generate --quiet
TEST_RUNNER_ZEUS_PROMPT_MODEL_URL=http://127.0.0.1:PORT \
xcodebuild -project Zeus.xcodeproj -scheme Zeus -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath build/DerivedData \
  -clonedSourcePackagesDirPath build/SourcePackages \
  -only-testing:ZeusTests/LiveManagedPromptAnswerTests test
```

Verified with Claude Code 2.1.296 and 2.1.299, Codex 0.162.1 and OpenCode
1.18.31. The test prints the installed version rather than pinning an
auto-updating CLI. Each test creates a private tmux socket, disposable
HOME/config and scratch project. The production launch/policy/MCP injection stay
intact; test-only overrides route model traffic to localhost. No user credentials,
agent configuration or default tmux server are used.

All three cases confirm a real permission dialog, a queued compose message with
zero attempts, no input before the click, precisely recorded native choice keys,
the actual command's output file, the “You chose …” history caption and delivery
of the queued message after the dialog clears. OpenCode is deliberately moved to
Reject before the test clicks Allow once; each Left is verified before Enter.
Evidence captures go to `build/p1-seam-<agent>.ansi`. Stop the model helper with
Ctrl-C afterwards. Permission parsing and refusal tests also run unconditionally
in `ManagedPromptAnswerTests`; the real-process suite is opt-in.
