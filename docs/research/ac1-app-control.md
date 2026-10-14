# AC1 runtime handoff

## Composition and ownership

Pass `appControl: shell.appControl` and `learnings: <L1 LearningsProviding store>` to
`ZeusRuntime`. Defaults preserve old initializers and fail closed: mutators are disabled,
the updater is unavailable, and learnings are empty. Runtime owns the store's
`onNewLearning` callback while started and releases it at stop.

`CardStore` must conform to optional `AppChangeRecording` (standalone commit `7f9473c`,
adopted by AC2). Shared currently declares `recordAppChange` only in an extension;
calling that through `any CardStoring` does not dispatch to the concrete store. PM
can instead promote it to a protocol requirement and keep the default implementation.
Every successful AppChange-returning method records its exact change/undo closure.
The irreversible install uses the required announcement; it does not invent an Undo.

Main `4ff0654` was merged with PM authorization; `setSize(String)` is used. No new
Shared, CONTRACT, project.yml or Package.swift edits were made directly by this branch;
the proposed contract wording below is for PM to apply.

## Exact proposed CONTRACT edits (PM applies)

### §3: additive, negotiated learning notification

Add to hello capabilities:

> `learningNotifications: Bool` is optional and defaults to false when absent.
> A new Claude bridge advertises it alongside `channel`. The app sends learning
> notifications only to bridges offering both capabilities, so old bridges never
> receive an unknown wire envelope. Wire version remains 1.

Add to the envelope table:

| Direction | Type | Fields |
|---|---|---|
| app→bridge | `learning` | `id`, `kind` (`digest` or `moment`), `text` |

> `BridgeClient.start` has an optional `onLearning` callback. Learning and push
> callbacks run serially in wire order; callbacks must not await another tool result.
> A learning announcement has no model/read acknowledgment and does not consume
> unread state. Non-channel and legacy sessions obtain learnings through polling.

### §12: arguments, results and update flow

Add:

> Creation tools take `name` and `json`, where `json` is complete UTF-8 JSON file text;
> the app's real loader validates it. `zeus_move.position` is a named placement or
> `{screen, x, y}` in screen points. `zeus_hide` requires exactly one of integer
> `minutes` in 1–720 or `until: "tomorrow"`. Appearance argument names are snake_case
> equivalents of AppearancePatch; omitted fields are unchanged. Unknown arguments
> are rejected. Turning quiet hours off is rejected while any open Zeus question
> exists, without revealing the question's content or creator.

> State and update-check results use their seam types' Codable fields.
> AppChange-returning mutators return `{ok: true, summary}`; `zeus_set_character`
> preserves `{ok, previous, current}`. AppControlError file/argument/updater messages
> are preserved verbatim as the compact JSON result's `error` value, with `isError`.
> Validation failures post no chat line. Update checks are master-switch gated too.

> Each session must have seen the exact version in its own successful update check.
> Installation announces "Updating to X — back in a few seconds", then waits for
> that session's other in-flight Zeus tool calls, waiting asks, transport sends and
> journaled pastes, and for the managed session's blocking prompt to clear. After
> 60 seconds it proceeds anyway, provided the runtime is still active and both
> control switches remain enabled. The install seam returns Void: installation is
> irreversible and its announcement is the history line, rather than an artificial
> AppChange Undo. If installation fails after announcement, its reason is added to
> the calling session's thread, returned by this call, and returned once again by
> that session's next tool call. Other sessions do not receive that error.

> Card update/dismiss tools cannot access another session's card or change local
> native-prompt/Terminal notices. An explicit delivery-ledger handoff allows the
> receiving session to update its earlier-session card, preserving §4's rerouting.

### §13: result consumption

Add:

> `zeus_get_learnings` returns `{learnings: [Learning]}` oldest first, newest last,
> in batches bounded by the link's 4 MiB frame size. Disabled learning returns an
> empty array. Only a successfully written tool result marks through its last
> returned learning ID as read; failed writes/disconnects do not consume anything.
> Announcements do not mark read. The MCP notification is exactly
> `notifications/zeus/learning` with `{id, kind, text}`. No raw events cross either
> interface. The L1 store owns the quiet summary/View history presentation.

## Evidence and verification

- `scripts/build.sh`: passed, no new warnings. The existing ManagedTerminal unused
  binding and ambiguous Xcode destination warnings are unchanged.
- `scripts/test.sh`: passed, 661 app tests; all package/release tests passed.
- Real Claude Code **2.1.299**, private tmux socket, 120×40 pane, disposable HOME and
  CLAUDE_CONFIG_DIR, scratch project and localhost model: both `zeus_app_state` and
  `zeus_move {position: "near-active-window"}` returned success. The branch-built
  dev bridge called the production headless runtime with fake app control; exactly
  one move was recorded. No paid inference or real user configurations/credentials.
- Scrubbed results: `TestFixtures/live/ac1-claude-app-control.json`.
- Reproduce from the worktree root after building:
  `python3 -B Zeus/App/Tests/Runtime/AC1LiveProbe.py`.
  The script builds the E2EHost pattern in `build/ac1-live`, supplies launch-only MCP
  configuration and explicit allow rules for these two tools, and cleans up every
  probe-owned process/socket/scratch directory. It includes AC2's ThreadNotice source
  automatically when that foundation is present after merge.
- AC2 read-only cross-review found a cancelled-before-check Sparkle state leak and
  stale cancellation risk. AC2 fixed these with request IDs and never-started-cycle
  cleanup (`4e40bfc`); re-reading confirmed both protections.
