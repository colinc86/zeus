# Preserve system facts in learning payloads

## Cause and correction

The payload redactor treated detail keys, system identity values and captured
user text alike. Both the pattern/name pass and the semantic pass could therefore
replace Warp with a privacy placeholder, alter a frame ID, or change a schema key.
Typing also passed its app label as prose, and screen metadata applied an
account-hint filter to the app label.

`JournalPayload.systemDetailKeys` is now the explicit allowlist shared by the
production payload redactor and the protocol's default implementation. It covers
OS app identity and Zeus-generated IDs, engines, kind/level markers, counts,
durations and retention metadata. Keys stay exact. Unknown detail values, titles,
URLs, document paths, descriptions, topics and typed words still run through
redaction. The semantic request includes only user-content values; a system-only
payload skips it entirely. Typing still requires successful semantic redaction of
its words, and the capture exclusion/private-context guards remain in force.

## Before / after

Synthetic fake model: it labels every remaining occurrence of Warp as health information.
The mandatory first pass may already have replaced it as a name.

| Field | Before | After |
|---|---|---|
| OS app name | `appName: ‹name›` / `‹secret›` / `‹health›` | `appName: Warp` |
| Engine (fake model also targets this value) | `descriptionEngine: ‹secret›` | `descriptionEngine: onDeviceModel` |
| Captured title containing Warp | privacy placeholder | privacy placeholder |
| Description containing Warp | privacy placeholder | privacy placeholder |
| Old stored app name plus retained bundle ID | digest/export app `‹name›` | resolved app name, e.g. `Warp` |

The user's supplied evidence also reports `‹name›` and `‹secret›` for the same app;
all are handled identically. No user journal or learning folder was read.

## Existing data

A shared app-identity resolver first uses a valid stored display name. For a
missing/placeholder name it looks up the retained bundle ID through local
LaunchServices and reads the app bundle's display/name metadata, with a per-process
cache. It never launches an app or opens its documents. If the app is unavailable,
the last bundle-ID component is the fallback. Folder export and reflection use
this identity, as does conversion of old journal activity into daily statistics.

Only the rendered identity is repaired: the encrypted source row, private title
and prose are unchanged. Without a retained bundle ID, an old placeholder name
cannot be recovered. Other previously damaged system fields cannot be inferred
and are not fabricated.

## Verification

- Build-for-testing passed; no new source warnings.
- 63 focused tests across redaction, typing, screen capture, folder facts and
  reflection passed before adding the additional system-app lookup regression.
- Final system/migration focused check: 10 tests passed, including native
  LaunchServices lookup and the updated legacy migration expectation. The old
  expectation redacted OS identity; its replacement also asserts that the same
  bytes remain redacted in the prose description.
- Tests cover system-only model omission, exact keys, unknown-value redaction,
  excluded Warp never reaching the typing processor, screen/typing identity,
  legacy export/digest recovery, unchanged source rows and private window titles.
- Full `scripts/test.sh`: 1,210 app tests in 245 suites passed (454.782 s),
  274 package tests and offline checks passed.
- Full `scripts/live.sh --quick`: 25/25 probes passed, no skips (537.10 s),
  including 28/28 E2E tests. Tmux hygiene clean; no fixture servers remain.
- Public-content check passed.

Build products were confined to `build/tmp/fx12/`. The entire `build/tmp/` and
build aliases were deleted after verification. Small logs/summaries remain at
`build/fx12-*`; the final full-suite log is `build/fx12-full-verified.log`.
