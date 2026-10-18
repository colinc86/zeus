# PA1 proactive delivery proof

Recorded 2026-10-17 using real Claude Code 2.1.302, the production managed
controller/runtime, bundled zeus-mcp, a private tmux socket, disposable HOME and
project, a localhost deterministic model, and an injected encryption key. No
user agent config, credentials, default tmux server or assistant folder is used.

Run:

```sh
scripts/live.sh --quick --only pa1-brief,pa1-trigger --agents claude
```

- `pa1-brief.json`: capture disabled; first activity creates one brief request.
  Claude calls `zeus_present` with `about: "Morning brief"`, then `zeus_ack`.
  Repeated activity does not duplicate it. The next fixture day has nothing to
  flag: only `zeus_ack`, with no additional card. Both receipts contain exactly
  the delivered request. All attempts are 1.
- `pa1-trigger.json`: one previously shadowed and approved acting rule, plus one
  unapproved shadow rule, transition to matching. Claude calls `zeus_rule_acted`
  for the former and `zeus_rule_shadow` for the latter, then acknowledges each.
  Two durable action records, no message cards and no external action. All
  attempts are 1.

The local model deliberately chooses the tools. This proves native submission,
MCP dispatch, runtime validation, durable acknowledgement and receipt handling;
it does not measure a model's independent judgment about when to interrupt.
The fixture clock advances normally within a synthetic date so busy postponements
can become due, and jumps a day only for the second brief.

Initial probe attempts exposed fixture mistakes, not successful proof: the model
parser selected an instruction's example envelope; the active rule had not yet
been marked shadow-shown; and a frozen clock prevented postponed sends becoming
due. These are corrected in the recorded passing run. Diagnostic state and policy
logs remain in the ignored build directory; the committed JSON is path-scrubbed.
