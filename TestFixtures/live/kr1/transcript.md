# KR1 — Talk shortcut recorder

Recorded 2026-10-14 on the unlocked console. Production TalkHotKey, ZeusShortcutRecorder, GlobalHotKey and ShellController, compiled into a private dev app. Disposable HOME/preferences/history, no agent, tmux server, configuration or credentials. No global keyboard monitor, Accessibility request or screen capture.

## Native live check

Reproduce with `python3 -B Zeus/App/Tests/KR1LiveProbe.py` after building once. Its output is under `build/kr1-live/`; it refuses a non-private HOME. `proof.json` is the successful native run after the shutdown fix.

1. Launch the dev host with an unused private test binding (⌃⌥⇧F19), so it does not compete with the human's running Zeus/default. Initial Carbon registration succeeded.
2. Native key-view traversal reaches the recorder. Space starts it. The real window-local NSEvent monitor receives ⌃⌥Space, unregisters the prior binding, registers the candidate and saves the key code/modifiers. Restoring AppSettings confirms the saved preference. No registration error.
3. Hide the Settings fixture, then post only the assigned ⌃⌥Space down/up pair. The host first checks existing native event-post access and refuses to request permission if unavailable. Access was already available for this run. The real Carbon hotkey callback opens the production Talk panel; it is both visible and mounted.
4. Exit the fixture and remove its HOME. No human settings or default shortcut are changed.

## Model / lifecycle checks

- Letters, digits, F1–F20, punctuation, arrows, navigation/editing keys and keypad keys have distinct physical codes and display/menu equivalents. F1–F19 are required; F20 and ISO/JIS keys are also represented.
- Legacy letter JSON decodes to its hardware code. An unchanged legacy preference keeps its old fields/encoding; editing a key stores `keyCode` along with the display key and modifiers. Default remains ⌥⌘Z.
- Non-function keys require Command, Option or Control; function keys can be bare. The specified Command-Q/W/comma/Tab combinations and unknown codes are rejected before registration.
- Start/capture, Escape cancel, Delete clear, reset, invalid input and taken-shortcut rollback are tested. Plain Tab cancels recording and continues traversal; modified Escape/Delete/Tab remain assignable. Modifier-only events are not captured; autorepeat cannot accidentally finish recording.
- Carbon refusal leaves the old saved binding and displays one “That shortcut is taken by another app.” line. This also applies if macOS owns bare F5. The F5 refusal render uses an injected registrar, without changing a system binding.
- Stop followed by a delayed recorder cancel or Settings observer cannot re-register anything. Only explicit Shell startup reactivates the registrar. Platform identified this lifecycle edge in review; the focused regression passes.
- Non-letter menu `keyEquivalent`/modifiers and the dynamic caption are checked. Welcome's hint uses the current shortcut, only when enabled and valid, and stays outside D19's body/peek text.

## Look / accessibility

The PNGs are native offscreen NSHostingView cache-display renders at 1× and 2×, not screen captures. Light and dark each include idle, focused, both recording pulse phases, None, disabled and taken-error. The designer approved the final corrected matrices: aligned crisp ring, stable row height, correctly dimmed reset/value and one error directly under the field. No ZeusDesign edits.

The native field exposes “Talk to Zeus shortcut” with its glyph value, accepts Space/Return to record, and announces Recording, result or cancellation. Native local-monitor tests check the value, recording and disabled states. The ring is steady under Reduce Motion; otherwise only its opacity pulses between 1 and 0.5, with the normal field border underneath.

## Verification

- First focused app run: 32 tests in 5 suites passed.
- Native/model/render check: 7 tests in 2 suites passed, including both appearance/scale matrices.
- Shutdown fix: 6 focused model tests passed. Platform re-review found no further blocker.
- `scripts/build.sh`: passed, no new warnings; existing Sendable warnings remain in untouched appearance/character/privacy Settings views, plus the scripts' existing ambiguous destination warning.
- Final `scripts/test.sh`: pending summary after lifecycle fix.
