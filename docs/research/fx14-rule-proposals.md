# FX14 — app names and partial rule proposals

## Cause

The advertised apps field accepted arbitrary strings, while PersistentRulesStore.validate required bundle IDs. A single invalid rule failed the entire batch with LearningStorageError.invalidRule. The reflection/template supplied app names, so the first real music-focus rule could not be saved. This report uses synthetic fixtures only, not the user's journal or assistant folder.

## Contract and implementation

- Resolve trigger.apps against names and bundle IDs in permitted journal observations, case-insensitively. Observed names win. If none match, consult application bundle metadata in Applications/System Applications and verify registration through LaunchServices. No apps are launched. Unknown/ambiguous names reject only their rule; ambiguous errors list candidate bundle IDs. Direct bundle IDs remain supported.
- Store canonical bundle IDs. Empty/oversized app entries are rejected.
- Return ordered, one-based results for every input. Accepted entries include ID and status; rejected entries include a rule-indexed reason and corrective hint. The existing rules array contains accepted rule objects. Partial success is not a tool error; wholly rejected batches are.
- Preserve one atomic store write and one review group for accepted entries. Only accepted proposals consume the three-per-day allowance. Rejected entries can be corrected without resubmitting accepted ones.
- Identify sentence, confidence, time, weekday, evidence, trigger and decoding errors. Confidence outside the advertised 0.4–0.7 range now rejects instead of silently clamping. Suppression and daily-limit messages retain their existing guidance, with rule indices.
- Recheck generation/admission/permissions and retained evidence across asynchronous redaction. Erasure cannot be undone by a late proposal.
- Schema and reflection instructions now document names, local minutes (07:45 = 465), and partial responses. Template v7 already says “an app named in the evidence”; it remains compatible and needs no hash/version change.

## Before / after tool responses

Before (reported dogfood response, matching the former generic validation path):

```json
{"error":"This rule has an invalid sentence, trigger, confidence or evidence."}
```

After, exact two-rule fixture: both results are accepted/active, with the second stored trigger apps equal to ["com.apple.logic10"]. Representative response projection below omits the full accepted rule objects and normalizes generated UUIDs:

```json
{"results":[{"index":1,"result":"accepted","id":"rule_1","status":"active"},{"index":2,"result":"accepted","id":"rule_2","status":"active"}]}
```

With a typo in the second rule, the first is saved:

```json
{"results":[{"index":1,"result":"accepted","id":"rule_1","status":"active"},{"index":2,"result":"rejected","reason":"rule 2: trigger.apps \"Lgic Pro\" isn't an app Zeus has seen or found installed; use the app's name as shown in the reflection, or its bundle ID."}]}
```

An invalid time returns:

```json
{"rules":[],"results":[{"index":1,"result":"rejected","reason":"rule 1: trigger.time startMinute and endMinute must be local minutes after midnight from 0 to 1439 (07:45 = 465)."}]}
```

## Verification

- Focused: 41 tests / 5 suites passed. Exact two-rule payload, case-insensitive/ambiguous/installed resolution, typo partial acceptance, daily quota, suppression, malformed fields, and existing learning/storage/evidence tests.
- Existing confidence-clamping and generic-error-type assertions were updated to the new explicit contract; their suppression/atomicity assertions remain.
- Grepped package/runtime tests for old schema argument lists and validation expectations. No tool argument keys changed.
- RF1 live fixture now proposes Xcode by name and asserts the stored trigger is com.apple.Xcode.
- Final build passed without new warnings; public-content check passed. All task build output under build/tmp/fx14 was deleted before handback.
- Final full scripts/test.sh passed: 1,236 app tests / 250 suites (1,198 passed, 38 expected skips), 618.356 s; all 276 package tests and offline checks passed. Tmux hygiene clean.
- RF1 real-Claude app-name probe passed in 33.41 s. Complete scripts/live.sh --quick passed 25/25 probes, including private-tmux E2E, in 577.11 s. Tmux hygiene clean.
- An earlier full run was stopped to remove an unintended concrete-store dependency from the headless runtime. Validation and the bundle-ID predicate now live in shared code; the final full gate includes headless Debug/Release compilation.

## Actual live response

RF1 supplied the name Xcode. This is the returned JSON, with only its generated rule ID normalized:

```json
{
  "results": [
    {
      "id": "rule_live",
      "index": 1,
      "result": "accepted",
      "status": "active"
    }
  ],
  "rules": [
    {
      "author": "agent",
      "confidence": "Fairly sure",
      "created": "2026-10-15T01:15:00.000Z",
      "evidence": [
        "j_13_mail",
        "j_0_mail"
      ],
      "id": "rule_live",
      "kind": "passive",
      "sentence": "Keep routine updates quiet during morning project work",
      "status": "active",
      "trigger": {
        "apps": [
          "com.apple.Xcode"
        ]
      },
      "updated": "2026-10-15T01:15:00.000Z",
      "updatedBy": "agent"
    }
  ]
}
```
