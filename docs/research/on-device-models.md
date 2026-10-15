# On-device models for Learn from me (LM2 spike)

**Question:** what can Zeus use on the Mac to redact and describe what it observes, before anything is stored or sent?
**Answer in one line:** use patterns, `NSDataDetector` and `NLTagger` for every item, use the on-device Foundation Model as a batched second pass for prose (health, money, secrets in words), and later use it for screenshot descriptions. Private Cloud Compute exists but isn't usable or appropriate here.

**Conditions:**
- M1 Pro, macOS 27.0 (26A428), Xcode 27.0 (27A266a), Apple Intelligence on.
- All inputs are synthetic: a 194-word made-up team note and a drawn 1280×800 fake Xcode window. No real screen, account or text was used.
- The program is `docs/research/on-device-spike/main.swift`. Build it with `xcrun swiftc -O -swift-version 6 main.swift -o spike`, then run `./spike 5`, or `./spike 3 --pcc` to also try Private Cloud Compute.
- Timings are wall-clock, in milliseconds. "Warm" is the median after the first call.

## 1. What the SDK offers

| | On-device `SystemLanguageModel` | `PrivateCloudComputeLanguageModel` |
|---|---|---|
| Availability API | `.availability`: `.available` / `.unavailable(.deviceNotEligible / .appleIntelligenceNotEnabled / .modelNotReady)` | `.availability`: `.available` / `.unavailable(.deviceNotEligible / .systemNotReady)`, plus `quotaUsage` |
| On this Mac | available, variant **"AFM 3 Core"** (`.core3`; `.coreAdvanced3` also exists) | reports `.available` |
| Context | **4,096 tokens** (`contextSize`; `tokenCount(for:)` since 26.4) | 32,768 tokens |
| Capabilities | guided generation, tools, **vision (image input)**; no reasoning | guided generation, tools, vision, reasoning |
| Structured output | `@Generable` / `@Guide` (counts, enums, descriptions) | same |
| Image input | `Attachment(cgImage)` in a prompt (macOS 27) | same |
| Use cases | `.general`, `.contentTagging` | — |
| Guardrails | `.default`, `.permissiveContentTransformations` | — |
| Can Zeus call it? | yes, no entitlement | **No.** Every request fails with `ModelManagerError 1046`, both from a command-line tool and from an ad-hoc-signed app bundle. The SDK doc says PCC needs a managed entitlement ("Accessing Private Cloud Compute", developer.apple.com/private-cloud-compute) and has a per-user quota. |

**Is any Apple cloud model reachable from third-party apps?**
- **Yes, on macOS 27, but only with Apple's managed entitlement:** `LanguageModelSession(model: PrivateCloudComputeLanguageModel())`.
- **Without the entitlement, no.** So the PM's belief (on-device only) holds for Zeus today.
- **Even with the entitlement, it's the wrong place for the Redactor.** Raw text would leave the Mac to reach it, which breaks principle 1 in `docs/design/PRIVACY.md`. A later reflection over already-redacted summaries could use it, and the sheet would have to say so.

## 2. Measurements

| Task | Tool | Cold | Warm (median) | Result on the fixture |
|---|---|---:|---:|---|
| 200-word redaction, find everything | on-device, `.general`, `SensitiveSpans` | 4,866–5,702 | 4,320–4,403 | **Poor.** Email and phone labelled as names; all four person names missed; health missed |
| same | on-device, `.contentTagging` | 3,337 | 3,320 | Worse ("quick notes" as an address) |
| 200-word prose pass on stage-1 output | on-device, `.general`, prose kinds only | 3,810 | 3,815–3,847 | Found the password in prose, "knee", "4,200 euros", "4242", "3rd". False positives "10", "secret", "Café Lumen". Missed "dentist appointment" and "prescription refill" |
| per-sentence yes/no flags | on-device, even with `.permissiveContentTransformations` | — | — | **Threw `guardrailViolation`** ("May contain unsafe content") |
| names, places, organisations | `NLTagger(.nameType)`, `.joinNames` | 34 | **2** | Every person name (full and first-only). Harmless extras: "Northwind" as a place, "Codex" as an organisation |
| emails, phones, addresses | `NSDataDetector` | 35 | **4** | Email, phone, street address |
| 1280×800 screenshot description | on-device, image in, `ScreenDescription` | 6,853–8,954 | **2,464–2,632** | `Xcode`, `ManageSessionController.swift` (one letter off), "Writing code for a session controller", `coding` |
| OCR, accurate | Vision `RecognizeTextRequest` | 65,018 (first use, model load) | 288 | 14 lines, file names readable |
| OCR, fast | same, `.fast` | 80 | 36 | 0 lines on light-on-dark code. Don't rely on it |
| face rectangles | `DetectFaceRectanglesRequest` | 5,750 | 19 | 0 (no faces in the fixture; latency only) |
| human rectangles | `DetectHumanRectanglesRequest` | 51 | 27 | 0 |
| "has the frame changed?" | `GenerateImageFeaturePrintRequest` | 79 | 16 | 768-float print, enough for the Phase B unchanged-frame check |
| any request | PCC | — | — | fails, entitlement (see §1) |

**Token budget:**
- The 194-word note is 284 tokens.
- The `SensitiveSpans` schema is 189 tokens and `ScreenDescription` is 269.
- With instructions included, one call can carry about 2,500 tokens of input, roughly 1,700 words or 20–40 window titles.

**Core ML PII model:** not measured. No small, licence-clean converted model was at hand offline, and the spike shows `NLTagger` already covers names at 2 ms.
- A custom model would add tens of MB, plus a licence and an update burden, for the one gap left: health and money in prose.
- The Foundation Model covers that gap with no download.
- **Recommendation:** don't ship a Core ML PII model in Phase A. Revisit only if the redactor's fixture recall on the prose kinds stays below target.

## 3. Recommended stack

1. **Stage 1, always, synchronously (a few ms):** patterns (keys, tokens, cards with Luhn, IBAN, SSN-like, 2FA, private keys, "password: …"), `NSDataDetector` (email, phone, address, links), and `NLTagger` person names. It never depends on the model.
2. **Stage 2, the on-device model, batched:**
   - It only **adds** redactions for health, money, secrets in words, and names `NLTagger` missed. It runs on stage-1 output and never un-redacts.
   - Items wait in memory, never on disk, and are flushed every 60 s or every 20 items in one call.
   - If the model is unavailable, errors, hits a guardrail or takes longer than 8 s, the batch is stored with stage 1 only and `RedactionReport` says the model pass was skipped and why.
   - Typed text (Phase C) fails closed instead: the item is dropped.
3. **Serialise** through one actor: the model takes one request at a time. Use a fresh session per batch, `samplingMode: .greedy`, and `tokenCount(for:)` to stay under budget.
4. **Post-filter** the model's spans:
   - Find each span by exact text.
   - Drop any span that isn't found, contains `‹`, is shorter than 3 characters, is a 1–2 digit number, or is an instruction word ("secret", "password").
5. **Phase B (eyes):**
   - The feature print skips unchanged frames.
   - Accurate OCR runs on each new frame, and stages 1 and 2 run on that text. Matching regions and faces are blurred before anything is kept.
   - `ScreenDescription` is generated from the blurred frame. The description goes through stages 1 and 2 like any other text.
   - Expect about 3 s of model time per kept frame on an M1 Pro. At the brief's event-driven cap that's well under 1 % of a core averaged over an hour, but every call should still run at `.utility` priority and only on AC power or above 30 % battery.
6. **Settings** shows which stage ran: "Private details are removed on this Mac (Apple Intelligence on)" or "(Apple Intelligence off: patterns only)", per `docs/design/PRIVACY.md`.

## 4. Schemas

Sent to platform for the Redactor:

```swift
@Generable(description: "Private details still left in text after Zeus's pattern pass")
struct ProseRedaction {
    @Guide(description: "Each private detail, copied exactly from the text. Empty if there are none.", .maximumCount(24))
    var spans: [ProseSpan]
}
@Generable struct ProseSpan {
    @Guide(description: "The exact characters from the text, unchanged; never a ‹placeholder›")
    var text: String
    var kind: ProseKind
}
@Generable enum ProseKind { case personName, health, finance, secret }
```

Instructions: *"Text arrives with some details already replaced by ‹…› placeholders. Find what is still private: names of private people, health (illness, medication, therapy, medical appointments), personal money (amounts, salary, debts, card or account hints), and secrets written in words (a password or PIN given in prose). Copy each exactly. Ignore placeholders. Ignore work topics, products, apps and companies."*

Placeholders follow platform's `RedactionKind` (`Zeus/Learn/Seams.swift`): `personName` → `‹name›`, `health` → `‹health›`, `finance` → `‹finance›`, `secret` → `‹secret›`, alongside stage 1's `‹email›`, `‹phone›`, `‹card›`, `‹iban›`, `‹identity›`, `‹address›`.

Phase B:

```swift
@Generable(description: "A short, factual description of a screenshot of one Mac window")
struct ScreenDescription {
    @Guide(description: "The app in front, by name") var app: String
    @Guide(description: "The document, file, page or conversation title shown, or empty") var document: String
    @Guide(description: "One sentence, at most 25 words, saying what the person is doing. No names of private people, no numbers from the screen.") var summary: String
    var activity: ScreenActivity
    @Guide(description: "Up to three topic words", .maximumCount(3)) var topics: [String]
    @Guide(description: "True if the screen shows private messages, health, banking, or a password") var looksPrivate: Bool
}
@Generable enum ScreenActivity { case coding, writing, reading, chatting, meeting, designing, browsing, email, other }
```

`looksPrivate == true` drops the frame and keeps only the description's `app` and `activity`.

## 5. Open points

- **Recall on prose health terms is weak** ("dentist appointment" was missed). Platform's fixture corpus should measure it. A small keyword list for health and money terms in stage 1 is cheap insurance.
- **First-use costs are large:** accurate OCR took 65 s and face detection 6 s on first use, while models load. Warm them at the moment the user turns a level on, not at the first capture.
- **PCC needs Apple's entitlement and changes the privacy story.** It's a product decision for the user, not a Phase A item.
