# What the assistant learns from Zeus, and how it should use it

The agent-facing side of Learn from me (LM2 Phase D). `PRIVACY.md` covers what the *user* sees. This file covers what the *assistant* receives, how it asks for more, how it proposes and runs rules, and the instructions it reads in its folder (§6).
- **Status:** shipped (Phase D, 0.2.3). The shipped tool shapes are `zeus_get_journal {query?, from?, to?, kinds?, raw?, limit?}`, `zeus_rule_shadow {ruleID, wouldHave, amount?, currency?}` and `zeus_rule_acted {ruleID, did, undo?, approvalID?}` (CONTRACT §13, Phase D). §5 describes them as shipped; the verb/object design is kept in §5.1 for the wording it produced.
- **Voice:** the assistant speaks as Zeus (see `Zeus/Resources/AssistantTemplate/AGENTS.md`): warm, brief, capable, and never commenting on the user's habits.

## 1. Principles for the assistant

1. **Use what you learn; don't talk about it.** Learnings change *when* you speak, *what* you have ready and *how* you say it. They're never the subject of a message unless the user asks.
2. **Ask the journal only to serve a request.** That means a question the user asked, or preparation for something the user asked for. Never browse out of curiosity.
3. **Nothing learned goes to other people.** No summary, topic, picture or quote from the journal goes into a message, file or post for anyone but the user.
4. **Rules describe behaviour, not people.** "Hold routine messages after 18:00", never "Don't bother me when I'm with Sam".
5. **Shadow means don't act.** A rule waiting for the user's OK is not permission. Report what you would have done; don't do it.

## 2. What the assistant receives, and when

| When | What | How | Contains |
|---|---|---|---|
| Session start | Active and shadow rules, and the user's "New rules" dial | `zeus_get_rules` (call it once at the start of every session, and again after a reflection) | Rule sentences, triggers, kind, status, a confidence *word* (Sure / Fairly sure / Unsure). Never a number to repeat. |
| Each morning | Summary of the day before | `notifications/zeus/learning`; `zeus_get_learnings` | Level 1 timing, plus redacted window titles (Level 2), screen descriptions (Level 3) and typing topics (Level 4) for the levels that are on |
| During the day | Up to four short notes ("back from a break", "winding down") | the same | One line each |
| Start of the day (PA1, §8.2) | **Brief request** | A delivery marked `kind: brief`, at the first activity or the set time; works with learning off | The date, the ask for one `zeus_present` labelled "Morning brief", the day's remaining budget, and a `Files:` line when there is a summary |
| A rule's trigger matches (PA1, §8.2) | **Rule trigger** | A delivery marked `kind: ruleTrigger`, once per rule per window; acting and "prepare" rules only | Rule id, text and status, what matched and the window, what to call (`zeus_rule_acted` or `zeus_rule_shadow`), the remaining budget |
| First idle ≥ 10 min after 18:00 (once a day) | **Reflection** | A delivery marked `kind: reflection`, through the normal message path. It's not a user request. | The day's summary, the **outcomes** of every rule since the last reflection (§5), the rules the user turned off, edited or deleted, and the journal item ids usable as evidence |
| When the assistant asks | Journal answers | `zeus_get_journal` (§3) | Redacted items for a time range. Pictures or words only if the user allowed "raw on request" for that level |
| After a rule acts or is shown in shadow | Nothing new | — | The assistant reported it itself (§5) |

## 3. `zeus_get_journal`, from the assistant's side

Call this to answer a question about what the user was doing ("what was I reading at 3?", "find the PR I had open this morning"), or to prepare for something they asked for.

**Input**

| Field | Type | Meaning |
|---|---|---|
| `query` | string, optional | Words to match against titles, descriptions and topics ("pull request", "dentist"). Plain words, not a search syntax. |
| `from`, `to` | ISO 8601 local date-time | The range. At most 7 days per call; `to` defaults to now. |
| `kinds` | array of `focus`, `screen`, `typing`, `activity`, optional | Defaults to every kind whose level is on. Kinds for levels that are off return nothing and say so. |
| `raw` | boolean, default false | Ask for pictures (Level 3) or words (Level 4). Honoured only for levels where the user turned on **Raw on request**. Otherwise the answer says it was refused and returns the redacted form. |
| `limit` | 1–50, default 20 | Most recent first. |

**Output**

```json
{
  "range": "Tue 14 Oct 14:00–15:30",
  "items": [
    {"id": "j_8f2", "time": "14:05", "app": "Mail", "kind": "typing", "text": "Replying to a doctor about rescheduling an appointment"},
    {"id": "j_8f9", "time": "14:12", "app": "Chrome", "kind": "focus", "text": "Q3 planning – Docs · docs.example.com/d/‹id›"},
    {"id": "j_901", "time": "14:20", "app": "Xcode", "kind": "screen", "text": "Debugging a session restart that failed to resume.", "picture": null}
  ],
  "raw": {"screen": "not allowed", "typing": "not allowed"},
  "raw_requested": true,
  "note": "This answer is logged in What Zeus Kept › Sent to your assistant."
}
```

- **Text is always as stored.** Placeholders such as `‹name›` mean Zeus removed something. Never guess what was there, and never ask the user to fill it in for you.
- **With `raw: true` and permission:**
  - Screen items carry `picture`: an attachment the user can see in the ledger. It's still the covered picture, never the original screen.
  - Typing items carry the words as kept, which are still redacted.
- **Every call is visible to the user:**
  - The thread shows one quiet line: "Looked at your journal: Tue 14:00–15:30 · View" (`PRIVACY.md` §11.2).
  - The call is logged in Sent to your assistant.
  - So call once with a sensible range rather than many narrow calls.
- **Limits:** 20 calls an hour, at most 50 items, the answer bounded to 400 KB. A call made while every level is off returns `{"items": [], "note": "Learn from me is off."}`. Without `raw`, the statuses read `not requested`.
- **Errors are plain sentences** ("That range is longer than 7 days."). Fix the call; don't retry blindly.

## 4. Proposing rules (`zeus_propose_rules`, during reflection)

**When:** only in reflection, once a day. **At most 3 new rules a day**, and none is fine. The best rules come from patterns over several days, not from one day.

**Sentence style:** this is what the user sees in Settings › Rules and in "New rule: … · Review".
- Imperative, about your behaviour or Zeus's, at most 12 words: "Hold routine messages after 18:00 on weekdays." "Have the open pull requests ready at 8:50 on Mondays."
- No names, accounts, amounts or private details: "Reply to the landlord" becomes "Draft replies to housing emails for me to check".
- No habits stated as judgements: not "Stop procrastinating on email"; say what *you* will do.

**Triggers Zeus can enforce itself:**
- `time`: local minutes after midnight, optional weekdays (1 = Sunday). A range that crosses midnight wraps.
- `apps`: bundle identifiers taken from the reflection's evidence. Never guess one.
- `state`: only the facts the reflection lists as available, for example `tests failing`. An unknown state never matches.
- Dimensions combine with AND.
- A rule with no trigger is **guidance**: Zeus shows it and you follow it, but Zeus never holds messages for it.

**Kind:**
- `passive`: changes only when or how you and Zeus talk (timing, tone, what to prepare). It starts at once under Balanced.
- `acts`: does something outside Zeus (send, post, draft into someone else's tool, change a calendar, buy). It **always** starts in shadow (§5).

**Evidence and confidence:**
- `evidence` lists the journal ids from *this* reflection that support the rule: at least 2, and from at least 2 different days, for anything but a guidance rule. Invented ids are rejected.
- `confidence` is between 0.4 and 0.7. Zeus raises or lowers it from outcomes (§7). Don't inflate it.

**Never propose:**
- A rule the user turned off, deleted or retired in the last 30 days. The reflection lists them with a fingerprint, so check against it, and don't propose a reworded copy.
- A rule that widens your authority: answering your own prompts, changing your permissions, turning learning up.
- An acting rule that spends money unless the user has asked for that kind of help in conversation. Quote that request's date in the sentence's evidence.

**Good and bad:**

| Good | Bad (why) |
|---|---|
| "Hold routine messages while tests are failing." `state: tests failing` | "Don't interrupt Alex when stressed." (a name and a judgement; "stressed" isn't a state) |
| "Have Monday's open pull requests ready at 8:50." `time: 530–540, weekdays: [2]`, kind passive | "Check GitHub every morning." (no clear behaviour, no trigger) |
| "Draft a short reply to scheduling emails for me to check." kind acts | "Reply to Dr Osei's office." (a name; it should be a draft for review) |

## 5. Acting rules (Phase D)

**Shipped shapes.** `zeus_rule_shadow {ruleID, wouldHave, amount?, currency?}` and `zeus_rule_acted {ruleID, did, undo?, approvalID?}`. `wouldHave` and `did` are short, non-private sentences starting with the past participle ("sent “Running late, 10 min” to the team chat"); the runtime strips a leading "would have" / "I'd have" and shows "I'd have … · OK next time? · Not this", and later "Did: … · Undo" (or "· Not again" without `undo`). A shadow call returns `{action_id, approvalID, act: false, note}` and repeats return the existing action until the user answers. A purchase under a rule needs `amount` and a three-letter `currency`; Zeus itself posts the durable question "Approve this purchase?" with the amount, and `zeus_rule_acted` then needs that `approvalID` with the identical `did` text within an hour, single-use. The runtime never executes a purchase. Both tools refuse when the rule's trigger hasn't matched, when the rule isn't in the right status, when learning storage is locked, or from a session that isn't the assistant.

### 5.1 Behaviour (the design the shipped tools follow)

- **`zeus_rule_shadow`** (designed as `{rule_id, verb, object}`): call this *instead of* acting when a rule is in shadow.
  - `verb` is one of `sent`, `posted`, `drafted`, `changed`, `bought`, `booked`, `deleted`.
  - `object` is a short phrase with nothing private: "“Running late, 10 min” to the team chat".
  - Zeus shows "I'd have sent “Running late, 10 min” to the team chat · OK next time?". Don't act.
- **`zeus_rule_acted`** (designed as `{rule_id, verb, object, reversible}`; shipped as `did` plus an optional `undo` instruction): call this *right after* acting under an active acting rule.
  - Zeus shows "Sent “Running late, 10 min” to the team chat · Undo" when `reversible` is true. When it's false, the line ends with "· Not again".
  - **Undo** reaches you as a message carrying the `undo` instruction you gave (idempotent; it may repeat). Reverse it if you can and say so in one line. If you can't, say so plainly.
  - **Not again** turns the rule off. You don't need to do anything.
- **Each time an acting rule's trigger fires:** check the rule's status with `zeus_get_rules`, which is cached per session and refreshed by Zeus's notifications.
  - **Retired, off or proposed:** do nothing.
  - **Shadow:** call `zeus_rule_shadow`, at most once per rule. Zeus ignores repeats until the user answers.
  - **Active:** act, then call `zeus_rule_acted`.
- **Spending (`bought`, `booked`):** every purchase asks, every time (PM decision, 2026-10-14): `zeus_rule_shadow` with the amount, Zeus's own question, then `zeus_rule_acted` with the `approvalID`. A spend rule stays in shadow; there is no standing approval.
- **Never:** act under a rule from a reflection delivery itself, act for a rule whose trigger didn't fire, or chain one rule's action into another rule's trigger.

## 6. Instructions in the assistant's folder (AssistantTemplate)

**Status:** shipped. The template's "## Learnings and rules" section (R7) covers the journal, reflection v2 (three proposals, confidence 0.4–0.7, evidence from two days, suppression fingerprints), shadow and acted reporting, and the purchase flow with `approvalID`. The draft below is the short form it grew from; the template is the source of truth.

> ## Learnings and rules
>
> If I've turned on **Learn from me**, Zeus keeps a private journal of how I use this Mac and tells you what's useful in it. You get summaries, never raw activity.
>
> - **Start of every session:** call `zeus_get_rules`. Rules are how I like to work with you: when to stay quiet, what to have ready, how to say things. Follow them without mentioning them.
> - **Each morning** a summary arrives (`zeus_get_learnings`). Use it for timing and tone. A 9:30 start means the 8:00 question can wait.
> - **When I ask about my own day** ("what was I reading at 3?", "where was that PR?"), use `zeus_get_journal` with one sensible time range. I'll see a line that you looked, so look once. ‹placeholders› are things Zeus removed; don't guess them.
> - **Each evening** Zeus sends a reflection. If you see a pattern over several days, propose up to 3 rules with `zeus_propose_rules`: short, about what *you* will do, no names, with evidence from the reflection. Never re-propose something I turned off.
> - **A rule waiting for my OK is not permission.** Call `zeus_rule_shadow` with what you would have done, and don't do it. Once I've said OK, act, then call `zeus_rule_acted`. If I press Undo, reverse it if you can and tell me in one line.
> - **Never comment on my habits**, never quote my journal back unless I ask, and nothing from it goes into messages to other people.

## 7. Outcome model (semantics for platform)

Each outcome is recorded once per event id. The confidence words follow `PRIVACY.md` §5.3.

| User action | Signal | Passive rule | Acting rule (shadow) | Acting rule (active) | Δ confidence |
|---|---|---|---|---|---|
| "OK next time?" or "OK" in Settings | accepted | — | → active | — | **+0.10** |
| Acted line left alone for 24 h | accepted | — | — | counts | **+0.03** |
| A held message read normally after the hold ended | accepted | counts | — | — | **+0.02** (at most once a day per rule) |
| "Undo" on an acted line | undone | — | — | counts | **−0.30** |
| "Show" on a "Held 2 messages" line before the hold ends (the user overrode it) | undone | counts | — | — | **−0.10** |
| "Not again" on an acted line | toggledOff | — | — | → off | **−0.30** |
| "Not This" in Settings, or "No" on a shadow line | skipped | — | → proposed | — | **−0.20** |
| Skip on a question the rule prepared or timed | skipped | counts | — | counts | **−0.10** |
| Shadow line not answered in 24 h | ignored | — | counts (stays shadow) | — | **−0.05** |
| A result the rule produced, left unopened for 24 h (a prepared list, a draft) | ignored | counts | — | counts | **−0.05** |
| Toggle off in Settings | toggledOff | counts | counts | counts | **−0.30**, and not re-proposed for 30 days |
| Toggle on in Settings | toggledOn | counts | counts | counts | **+0.10** |
| Edit in Settings | edited | counts | counts | counts | set to **max(current, 0.60)**; author becomes user |
| Delete in Settings | — | — | — | — | removed; its fingerprint blocks re-proposal for 30 days |
| Trigger never matched in 30 days | stale | counts | counts | counts | **−0.10**, then every 30 days |

**Starting values and floors:**
- **Agent proposals** start at their stated confidence, clamped to 0.4–0.7.
- **User-written rules** start at 0.75 and **never retire on their own**. They can fall to "Unsure", but only the user removes them.
- **Retirement:** an agent rule retires when it falls **below 0.2**. It moves to Retired with the line "Retired a rule you kept skipping: “…” · Review", or "…you turned off" / "…that never applied" depending on which signal dominated the last 30 days.
- **"Turn Back On"** on a retired rule restores it at **0.5**, as active (passive) or shadow (acting).

**What changes from platform's Phase A values:**

| Outcome | Phase A | This table |
|---|---|---|
| accepted | +0.05 | +0.10 (explicit OK), +0.03 / +0.02 (implicit) |
| skipped | −0.15 | −0.20 (shadow "No"), −0.10 (a timed question skipped) |
| undone | −0.25 | −0.30 (acted), −0.10 (a passive hold overridden) |
| ignored | −0.10 | −0.05 |
| toggledOn | +0.05 | +0.10 |

New semantics:
- `edited` raises confidence to at least 0.60.
- A `stale` signal is added.
- User rules never auto-retire.
- A 30-day no-re-proposal fingerprint follows toggles and deletes.

## 8. PA1 · A proactive assistant

**Status:** in build (platform PA1-P deliveries and budget, appdev PA1-A Settings and the held line, designer PA1-D the prose). User direction 2026-10-17: "a true assistant that learns about me to provide proactive feedback, tasks, and whatever else I need. This is how a human would work next to me as my assistant in real life."

### 8.1 The stance

Every delivery from Zeus used to end in "ack and stay quiet". From template v6 the rule is: **on any learning, moment, brief request or rule trigger, decide whether something needs preparing or flagging now. If yes, prepare it and send one short message with an `about` label. If not, ack and stay quiet.** "Now" means: a meeting soon, a task the user put off, a reply they owe, a pattern the assistant can take off their hands. The guardrails stay and are restated wherever the stance is: never comment on habits or quote the journal; at most a few unprompted messages a day unless urgent (the budget below); ratings and "Stop these" always win; acting rules stay shadow until approved; every purchase asks.

### 8.2 Two new deliveries, and the budget line

Both go through the ordinary delivery path (`Delivery.Kind.brief` and `.ruleTrigger`), held while the user is drafting or the session is busy like other learnings, and end with the usual `Files:` line of existing folder-relative paths (omitted when none exist). Every learning-type delivery (digest, moment, brief, rule trigger) carries the budget line as its last line before `Files:`. The text is written in the user's voice, like a message from them, because the template says to treat Zeus messages as messages from the user.

**Brief request** (`kind: brief`), at the first activity of a new day, or at the fixed time the Morning brief setting names (§8.4). The brief carries its **own** short summary of yesterday, built from the levels that are on and already redacted (typing as topics only), so it never waits for the morning digest: the digest still goes out as its own learning delivery, and there is no ordering between the two. With learning off there is no summary block, only the date and "start of my day".

```
Start of my day: Friday 17 October.
Using yesterday's summary, your Notes/, my rules, and your own tools (calendar, mail, tasks) if you have them, send me one short brief of what matters today: what's coming up, what's at risk, what you've prepared. One zeus_present with about "Morning brief": a short title, then at most 6 lines, the most important first. If nothing matters today, zeus_ack and stay quiet.
Yesterday (from Zeus's journal, private details removed):
- Active 9:20–18:05, about 7 h at the Mac; lunch 12:30–13:10.
- Top apps: Xcode 3 h 10 min, Safari 1 h 20 min, Mail 40 min.
- Typing topics: release notes, a reply to ‹name›.
Unprompted messages left today: 6 (high priority doesn't count).
Files: Zeus/rules.md
```

The "Yesterday" block is at most 6 lines and only from the levels that are on (level 1 timing; level 2 window titles; level 3 picture descriptions; level 4 topics, never the words). With learning off the second line starts "Using your Notes/, my rules, and your own tools…" (no "yesterday's summary") and the block is absent. `Files:` lists only files that already exist: `Zeus/rules.md` when present, and yesterday's `summary.md` only if it has been written by then (never asserted).

**Rule trigger** (`kind: ruleTrigger`), when an evaluable rule of kind acting (or "prepare") transitions to matching; once per rule per trigger window; passive rules are never delivered. Active rule:

```
Rule trigger (active): "Send “Running late, 10 min” to the team chat when a meeting starts while I'm away" · rule r_ab12.
Matched: Calendar meeting at 14:00 while the Mac was idle since 13:48. Window until 14:30.
This rule is active: act on it now, then call zeus_rule_acted {ruleID: "r_ab12", did, undo} right away. If this trigger doesn't call for anything, zeus_ack and stay quiet.
Unprompted messages left today: 4 (high priority doesn't count).
Files: Zeus/rules.md
```

Shadow rule: the first line reads `Rule trigger (shadow, waiting for my OK): "…" · rule r_ab12.` and the third line reads `This rule isn't approved yet: call zeus_rule_shadow {ruleID: "r_ab12", wouldHave} with what you would have done, and don't do it. Then zeus_ack.` The "Matched:" line is the trigger's own words (the time window, or the app named in the rule) plus the clock times, never journal detail beyond what the trigger names.

**Ledger and waiting rows (LM4 surfaces).** The two kinds get their own labels so the LM4 fallback never calls them "Daily summary": waiting-row titles **"Morning brief request"** and **"Rule trigger"**; the quiet prepared line **"Morning brief request ready for your assistant"** and **"Rule trigger ready for your assistant"** (never "Sent" before the receipt); once received, **"Sent the morning brief request"** and **"Sent a rule trigger: “<rule text>”"**, the rule text tail-truncated like a note's.

**Budget line.** `Unprompted messages left today: N (high priority doesn't count).` N is the day's remaining soft budget (default 6). At zero: `Unprompted messages left today: 0. Anything more arrives held unless it's high priority.` A held card is not deferred: it lands in the thread at once, collapsed (§8.5), and midnight resets the count without replaying anything. The line also goes on digests and moments so the assistant always knows.

### 8.3 Template v6, the MCP instructions and the managed launch prompt

The three say the same stance in their own register; the template is the long form and the source of truth.
- **Template v6** (`AssistantTemplate/AGENTS.md`): the "Learnings and rules" section gains the stance (§8.1) in place of "use them for timing and tone"; a "Start of my day" bullet for the brief (one `zeus_present`, `about: "Morning brief"`, title "Today", at most 6 lines, lead with the one thing that matters most; use calendar, mail and task tools when available; if nothing, ack); the rule bullet says Zeus delivers the trigger, so the assistant never has to watch for it; the budget line is explained next to the hourly rule of thumb; the session-start bullet reads rules, `Zeus/preferences.md` and `Notes/`; the Crons TODO says the morning brief is already asked for. Nothing else moves.
- **MCP instructions** (`ZeusMCP.instructions`): the delivery kinds list gains `brief` and `ruleTrigger`; the learning bullet says decide, prepare or flag, else ack; a bullet each for brief and rule trigger; the closing "timing and tone" line becomes "decide what to prepare or flag now, and timing and tone".
- **Managed launch prompt** (`ZeusManagedCopy.defaultLaunchPrompt`, MANAGED.md §6) adds two lines: read `zeus_get_rules` and the folder at the start of a session, and the stance; its last line now waits "for me or for a Zeus delivery". It stays under 2,400 characters.

### 8.4 Settings: Morning brief

A section **"Morning brief"** on Settings › Assistant, in both modes, directly above Quiet hours (MANAGED.md §1), section title `.title` in `palette.title`:
- Checkbox (`ZeusCheckboxStyle`): **"Ask my assistant for a morning brief"**. Default on when Zeus runs the assistant, off for Connect your own.
- Caption under it: "At the start of your day, Zeus asks your assistant for one short brief of what matters today: what's coming up, what's at risk, what it has prepared. It uses yesterday's summary when Learn from me is on, its own notes and tools, and nothing else. Rate it like any message."
- Under the checkbox, a `ZeusChoiceList` labelled **"When"** with two rows, disabled with the checkbox off:
  - **"After my first activity"** (default), detail "When you start using the Mac, within the first hour of the day."
  - **"At a fixed time"**, with an hour-and-minute `DatePicker` in `ZeusFieldChrome` beside the row's text (an HStack inside the choice row; `ZeusChoiceList` has no accessory slot and gains none), default 08:00; the brief goes at that time if the Mac is awake, otherwise at the next activity.
- Seam (platform): `enabled` is a persisted override; until the user toggles it, the effective value is the mode's default (managed on, Connect your own off, explicit opt-in allowed). `schedule` is `firstActivity` or `fixedTime` with hour and minute, default 08:00.
- VoiceOver: the checkbox by its label; the list as "When, After my first activity, selected" etc.; the time field "Brief time".

### 8.5 The thread: held over today's limit

When an unprompted card past the day's soft budget arrives (platform counts; `priority: high` is exempt, and ratings or "Stop these" are evaluated first, so a stopped kind is muted, not held), it reuses the muted presentation (CONVERSATION.md §17.5): it lands at once as one collapsed notice line "Held: over today's limit · Show", silent, not unread, expanding to the full bubble with a caption. Show releases the hold durably (the card stays a budget-held card by provenance; Hide collapses it again, presentation only). It keeps its ⋯ and rating row, because unlike a muted card nothing has been rated yet.

### 8.6 Renders

`pa1/pa1-<state>-<theme>-<scheme>` from `build/pa1-renders/`: `settings` (the Morning brief section, managed mode, both schedule choices), `held-collapsed`, `held-expanded`, and `held-day` (the end-of-day notice), in both fonts. Approved by the designer.
