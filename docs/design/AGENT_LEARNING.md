# What the assistant learns from Zeus, and how it should use it

The agent-facing side of Learn from me (LM2 Phase D). `PRIVACY.md` covers what the *user* sees. This file covers what the *assistant* receives, how it asks for more, how it proposes and runs rules, and the instructions it reads in its folder (§6).
- **Status:** design for Phase D. The tools in §3 and §5 don't exist yet.
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
  "note": "Logged in the user's What Zeus Kept › Sent to your assistant."
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
- **Limits:** 20 calls an hour. A call made while every level is off returns `{"items": [], "note": "Learn from me is off."}`.
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

New tools for acting rules. **Platform names and builds them; this is the behaviour to build them to.**

- **`zeus_rule_shadow {rule_id, verb, object}`:** call this *instead of* acting when a rule is in shadow.
  - `verb` is one of `sent`, `posted`, `drafted`, `changed`, `bought`, `booked`, `deleted`.
  - `object` is a short phrase with nothing private: "“Running late, 10 min” to the team chat".
  - Zeus shows "I'd have sent “Running late, 10 min” to the team chat · OK next time?". Don't act.
- **`zeus_rule_acted {rule_id, verb, object, reversible}`:** call this *right after* acting under an active acting rule.
  - Zeus shows "Sent “Running late, 10 min” to the team chat · Undo" when `reversible` is true. When it's false, the line ends with "· Not again".
  - **Undo** reaches you as a message: "Undo what you did for the rule “…”: <object>." Reverse it if you can and say so in one line. If you can't, say so plainly.
  - **Not again** turns the rule off. You don't need to do anything.
- **Each time an acting rule's trigger fires:** check the rule's status with `zeus_get_rules`, which is cached per session and refreshed by Zeus's notifications.
  - **Retired, off or proposed:** do nothing.
  - **Shadow:** call `zeus_rule_shadow`, at most once per rule. Zeus ignores repeats until the user answers.
  - **Active:** act, then call `zeus_rule_acted`.
- **Spending (`bought`, `booked`):** even when the rule is active, use `zeus_ask` with the amount before paying when it's more than the amount in the rule's sentence, or more than the last time.
- **Never:** act under a rule from a reflection delivery itself, act for a rule whose trigger didn't fire, or chain one rule's action into another rule's trigger.

## 6. Instructions in the assistant's folder (AssistantTemplate)

**Status:** the Phase A–C part shipped in LM2-D5 as the template's "## Learnings and rules" section. It differs from the draft below in three places:
- **At most two rules a night**, matching Zeus's reflection delivery.
- **Every purchase asks first, every time**, the 2026-10-14 decision.
- **No journal or acting-rule tools.**

The draft below is the full Phase D version.

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
