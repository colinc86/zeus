# LM2-B core integration

## Composition

The local Foundation-only frame values/capability extend `Zeus/Learn/Seams.swift`; no Shared or CONTRACT file was edited.
`ScreenSeams.swift` adds policy, context and optional observer APIs. App-owned Settings persists consent, scope and limits.

```swift
let windowSource = ScreenWindowContextSource(
    policy: { screenPolicy }, isLocked: { source.isLocked },
    browserPrivacy: { identity in privacyForExactWindow(identity) })
let screen = ScreenObserver(journal: journal, redactor: redactor,
    policy: { screenPolicy }, context: { windowSource.current() })
windowSource.start { [weak screen] in screen?.contextDidChange(returnedFromIdle: false) }
screen.start()
// On disable/shutdown: windowSource.stop(); screen.stop().
```

`enabled` and `consented` must both be true. Scope is everywhere-except or only-chosen, with the shared private list winning.
Default cap is **12** per hour (aligned with appdev/design coordination; the initial platform brief said 30). Descriptions
support 7/30/90 days, default 90; frames stay 7. Daily/policy-change screen pruning preserves other levels' custom retention.

The window source reads metadata only for a permitted front app, uses public AX focused-window bounds/title when available,
and uses the CG front window ID without a private AX window-number API. It watches workspace and AX focus/title events.
Without AX, CG metadata still supports app/periodic/on-demand capture; same-window document notifications require AX or an
app-supplied document event. The app should pass its own idle-return events when available; the observer also checks the
permission/idle deadlines without depending on Level 1 being enabled. Explicit factory/context reads never capture pixels.

Browser privacy is `.normal`, `.private` or `.unknown`, bound to `ScreenCaptureIdentity` (bundle/PID/window ID). Unknown
browsers fail closed even on an allow list. Safari's Level 2 title/URL exception is not sufficient to authorize Level 3.
The app owns L2 selection/URL chips; they are explicit Ask actions, redacted before staging. Nothing is sent before Send.

## Capture and permission

`WindowScreenCapture` uses only `SCContentFilter(desktopIndependentWindow:)`, checks foreground PID/window again after
shareable-content discovery, and captures a preview with longest dimension at most 1280. It never captures a display.
`ScreenObserver` revalidates policy/context/generation after each suspension and before synchronous journal storage.
Call `invalidatePendingCapture()` before journal deletion. Hard stops include lock, secure input, private context/apps,
camera, mirroring, presenting and sensitive app/dialogs. CoreMediaIO listeners track camera device changes; current running
properties are re-read at capture/storage boundaries and unknown/read/listener failure blocks capture. Keynote/PowerPoint
full-screen foreground windows are a conservative presentation check; the app can also supply `isPresenting` facts.

`requestPermission()` is an explicit consent-button action only. No timer/start/capture requests it. `permission` reports
preflight availability (including revoked). `lastPermissionRequestGranted` preserves the Boolean result of the explicit
request. `permissionGrantedRequiresReopen` is true only after positive grant evidence while preflight is still false.
The public CoreGraphics APIs are Boolean: a false result cannot distinguish denial, a pending Settings change or a grant
requiring restart. The app must not invent an "Allowed" state from a false result or read the TCC database.

`await captureOnDemand()` returns safe HEIC/boxes, redacted description, opaque identity, timestamp and journal IDs, or nil
when stopped/paused/changed/failed. An unchanged preview can reuse the verified stored result without a new kept frame.
Deleted pictures never return from that cache. App stages the result locally and owns explicit Send/Cancel attachment files.

## Processing

- 64×40 grayscale diff plus 64-bit dHash; unchanged requires same app/title, distance ≤2 and mean difference <0.3.
- Accurate Vision OCR, batched Redactor stages 1–2 on lines and metadata; cover entire changed/private lines with solid
  grey (+5 px). Screenshot account/routing/card hints and amounts are covered even if prose generation is unavailable.
- Saliency regions over 48×48 px and whole-frame faces (25% padding) are pixellated; no face tiling. Solid text covers run
  last, so picture processing cannot restore covered text. These detectors reduce exposure; they cannot guarantee perfect
  recognition of every private fact or picture, and whole-frame faces can miss small faces (see designer's spike).
- `FrameDescriber` sends covered OCR text plus redacted metadata to the on-device model, never pixels. Eight-second budget,
  greedy structured schema; NLTagger app/document/word-count fallback. Its result goes through Redactor again. A positive
  visible-secrets hint keeps only the description; the hint never overrides the mandatory redaction/hard stops.
- Low Power Mode/battery below 30% defer descriptions. Later work reads only covered stored HEIC through `CoveredFrameReader`;
  raw OCR is not kept. Vision prewarming uses generated pixels after consent. Raw frames/OCR never go to disk or logs.

## Journal, viewer and receipts

`EncryptedJournalStore` implements `FrameJournalStoring`. Images/boxes are AES-GCM `.zframe` files using hashed IDs and
logical-file authentication; a `.frame` text row is the commit marker. The viewer calls `frame(id:)` for the covered preview;
query/export/summaries contain metadata only. Descriptions link via `details["frame_id"]`. Morning L1 digests and reflection
sample at most four screen descriptions across the day; neither includes frames or their bytes.

`deleteFrame(id:includingDescription:) -> FrameDeletionReceipt` commits the paired day metadata atomically. Delete Picture
keeps the description with `picture_not_kept=deletedByUser`; expiry uses `expired`; model caution uses `private`.
`restoreFrame(_:)` restores exact bytes/metadata, rejects changed rows, and cannot cross Delete Everything/app/day forget
boundaries. Receipts are in-memory Undo tokens for that store instance, not persisted long-term exports. Normal capture
pairs share a day; inconsistent cross-day pairs are rejected before mutation. Orphan ciphertext from interrupted cleanup
is not readable through the journal and is reclaimed by prune/Delete Everything. Picture deletion before a deferred
 description exists creates a generated tombstone row. The app should invalidate pending capture before all delete actions.

For explicit context-chip sent rows, CardStore may conform to `LearningContextReceiptRecording`. Runtime emits
`LearningContextDeliveryReceipt` only for actual transport/ack/poll consumption or written blocking-ask results. Compose uses
`deliveryID`, replies also carry `cardID`. It includes stable receipt time, agent, path-free session label and SHA-256 session
identity. The adapter filters saved context intents and writes exact explicit-Send text/labels; it must not fabricate a row
from queued attempts. Confirmed ledger records replay at runtime start; adapter must be ready before start and deduplicate
its durable intent ID. This hook writes no journal rows by itself and does not enable capture.

## Gates and limitations

See `TestFixtures/live/lm2b/README.md`. Synthetic bank OCR/cover/HEIC/re-OCR, actual on-device schema generation and fake
hard-stop/lifecycle/storage tests pass. Full suites and focused results are logged under worktree `build/`. Native screen
proof is **incomplete**: this dev build has no Screen Recording permission, and unknown Safari privacy remains blocked.
No real Terminal/Xcode/Safari window or physical video call is claimed as verified.

References: [Apple single-window screenshot API](https://developer.apple.com/documentation/ScreenCaptureKit/SCScreenshotManager/captureImage(contentFilter:configuration:completionHandler:)),
[CoreMediaIO running-state property](https://developer.apple.com/documentation/coremediaio/kcmiodevicepropertydeviceisrunningsomewhere),
[permission preflight](https://developer.apple.com/documentation/coregraphics/cgpreflightscreencaptureaccess()).
