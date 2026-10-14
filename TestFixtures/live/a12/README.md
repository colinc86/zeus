# A12 native accessibility evidence

Captured 2026-10-14 from appdev's A12 code (`c41c882`, based on `b7dc9f6`).

- `ax/`: in-process `NSAccessibility` trees from real offscreen hosting views. Numeric checkbox values are the native
  checked state; slider value descriptions retain units. Raw `AXUnknown` implementation nodes are omitted.
- `renders/`: requested **Not Now** focus in every bundled theme, both appearances. A 4-point reference swatch at the
  upper left lets the pixel assertion compare the ring against the same theme token under the same display profile.
  These are view bitmaps (`cacheDisplay`), not screen captures.

The fixtures use isolated defaults/history, fake credentials/controller/activity source and disposable app bundles.
Personal build paths, if present in generated setup copy, are replaced with `/FIXTURE/Zeus.app`.

**Limit:** the lock-screen shield prevented the fixture app from becoming active/key. These artifacts prove exposed
labels/values/hints, native AX actions, Tab-loop order/uniqueness, and requested-focus rendering. They do not prove OS
initial first-responder assignment, actual Space/Return dispatch, or audible VoiceOver output. Three explicit opt-in
native keyboard regressions require an unlocked Mac; see [the audit](../../../docs/audit/a12-keyboard-voiceover.md).

Every fixture closes its windows and removes its temporary files/defaults on exit. No user's agent or config is used.
