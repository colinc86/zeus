# FB1-A: message ratings presentation

Branch: `appdev/fb1-ratings-ui`.

## Delivered

- Unprompted assistant cards expose a reserved, first-click rating affordance in the thread and peek. Replies, local cards and progress have none. Peek opens the thread at the card with its rating row ready.
- Inline kind/single-message scope, editable labels, existing-choice chips, durable guarded snapshot Undo and explicit removal use `MessageRatingsProviding`. Persistence errors remain visible; no optimistic preference or unavailable-store fallback.
- Held cards stay quiet: no unread count, avatar alert/speech, peek, reply target or new-message pill. Show/Hide expands the retained bubble without correcting it; Not this kind and Change rating use the runtime. The daily quiet summary uses quiet-hours start or 21:00 local and removes stale summaries when nothing remains held.
- Ratings lead Settings → Rules even with learning off. Suggestions use a quiet two-action thread notice.
- Committed seen transitions notify the runtime centrally, including direct peek answers, Skip, batch reads and automatically seen arrivals. Failed persistence emits no read callback. UI kind lookup uses the core's punctuation, case, diacritic and width normalization.

## Design and ownership

Designer approved the final native renders against `designer/fb1-ratings` `6ac83cc`: words-only choices and Settings segments, shared bare more glyph, distinct rest/hover/focus/open states, separators, muted Hide disclosure and a single Settings footer. No direct ZeusDesign or runtime edits; original-history designer/platform merges supply those changes. Optional suggestion wrapping remains the existing thread-notice layout.

`build/fb1-renders/` contains 80 native fixture PNGs covering all seven themes, both system modes and fonts, plus rating, muted, Settings and suggestion states. Appearance fixtures use the same affordance drawing as the interactive control; native input tests separately exercise the production conversation panel.

## Verification

- `scripts/build.sh`: PASS, no new warnings; final log `build/fb1-build-final.log`.
- Targeted app/core and existing conversation, persistence, peek, status-strip and first-click regressions: PASS, 87 tests / 10 suites in 30.262 seconds (84 passed, three expected opt-in skips): `build/fb1-focused-final.log`.
- Native private-window events verify one mouse press, Command-R toggle, arrow navigation into Edit, Return activation, actual text-editor focus, Escape reverting the draft then closing only the row, and Return selecting More like this. AX tests check labels/actions and compact-surface bounds.
- Renders: `TEST_RUNNER_FB1_RENDER=1` with the `FB1RatingsPresentationTests` selection; `build/fb1-renders-final.log`.
- Core's final real Claude proof and serial 20/20 quick gate are adopted from platform; see `fb1-ratings.md`. Appdev did not rerun that live gate or the PM-owned full suite.

All test cards/defaults/files are disposable fixtures. Native events target the test-host window, not the installed app; no global input events, real agent configurations or credentials are used.
