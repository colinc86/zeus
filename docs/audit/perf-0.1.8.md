# Idle cost of 0.1.8's new surfaces (PERF2)

**Result: every measured case stays within 2× of its P10 figure, so none counts as a bug under the PERF2 rule.** No case regressed. Two caveats:
- The console was locked during every run (see Conditions), so none of this is a visible-desktop acceptance run.
- Case 4 couldn't be measured faded: ghost mode never fades while the console is locked.

The Learn-from-me recorder got two fixes for idle hygiene:
- The idle poll is now suspended while the Mac is locked or asleep.
- Today's list is no longer re-read from disk on every event.

## Conditions

- **Machine and build:** M1 Pro, macOS 27.0, a Debug build of `designer/perf2-idle` (from main `6f6e159`).
- **Isolation:** `scripts/perf.sh` with its isolated `HOME`, `CFFIXED_USER_HOME` and `TMUX_TMPDIR`. The managed session is off, and there is no bridge. "Before" is main's code; "after" adds the recorder fixes below.
- **Interval:** each case is a 60-s CPU interval, after the script's 5-s warm-up.
- **CPU:** 100 % means one full core. The figure is the cumulative `ps` CPU time over the interval divided by the elapsed time.
- **Wakeups/s:** interrupt wakeups from `proc_pid_rusage`, the same counter Activity Monitor uses. Activity Monitor's "Idle Wake Ups" (package-idle) were 0.0–0.2/s in every run, so they're left out of the table. `top`'s `IDLEW` column read 0 for these processes, so it isn't used.
- **Energy:** `top`'s `POWER` over the same interval (Activity Monitor's energy impact).
- **Frames/s:** actual avatar pixel changes per second from `ZEUS_FRAME_COUNTER=1`.
- **Locked console:** the console was locked with the displays asleep for every run. Every window reported occlusion `8192`, which means not visible. As in P10, each case was therefore run twice:
  - **Normal gating:** zero frames, the production behaviour while locked.
  - **Occlusion bypass** (`ZEUS_PERF_IGNORE_OCCLUSION=1`): the controlled run that P10's 1.78 % and 1.65 % come from. Animation is live at about 7 frames/s.
- **Learn from me on:** the real `NSWorkspace` observers and idle poll ran inside the isolated home, which perf.sh deletes afterwards. Nothing recorded was read or kept.

## Results

| # | Case | perf.sh flags | Gating | CPU | Wakeups/s | Energy | Frames/s | P10 | Within 2×? |
|---|---|---|---|---:|---:|---:|---:|---:|---|
| 1 | Panel closed, idle, Learn off (baseline) | — | normal | 0.60 % | 1.0 | 0.6 | 0 | 0.89 % (locked) | yes |
| 1 | | | bypass | 2.18 % | 11.5 | 2.1 | 7.0 | 1.78 % | yes (1.2×) |
| 2 | Same, Learn from me **on**, idle poll running | `--learn` | normal | 0.80 % | 1.0 | 0.7 | 0 | 0.89 % | yes |
| 2 | | | bypass | 1.65 % | 11.6 | 1.6 | 7.3 | 1.78 % | yes |
| 3a | Panel open, strip "? Waiting for your answer" | `--question`, `ZEUS_PERF_PANEL=conversation` | normal | 0.60 % | 1.0 | 0.5 | 0 | 0.89 % | yes |
| 3a | | | bypass | 1.52 % | 11.8 | 1.5 | 5.0 | 1.65 % | yes |
| 3b | Panel open, the same question, typing indicator | + `ZEUS_PERF_ACTIVITY=thinking` | normal | 0.67 % | 1.0 | 0.6 | 0 | 0.89 % | yes |
| 3b | | | bypass | 1.53 % | 11.7 | 1.5 | 5.1 | 1.65 % | yes |
| 4 | Ghost mode at 0.3, panel closed | `--ghost 0.3` | normal | 0.98 % | 0.9 | 0.9 | 0 | 0.89 % | yes, but **not faded** (alpha 1) |
| 4 | | | bypass | 1.13 % | 11.8 | 1.1 | 7.3 | 1.78 % | yes, but **not faded** (alpha 1) |
| 5 | 300 messages, panel open, strip visible | `--history 300 --question`, `ZEUS_PERF_PANEL=conversation` | normal | 0.90 % | 1.0 | 0.8 | 0 | 0.89 % | yes |
| 5 | | | bypass | 2.10 % | 11.3 | 2.0 | 4.8 | 1.65 % | yes (1.3×) |

After the recorder fixes, same conditions:

| # | Case | Gating | CPU | Wakeups/s | Energy | Frames/s |
|---|---|---|---:|---:|---:|---:|
| 1 | Baseline | normal | 1.08 % | 1.0 | 1.0 | 0 |
| 1 | | bypass | 1.65 % | 11.6 | 1.6 | 7.3 |
| 2 | Learn from me on | normal | 0.70 % | 1.0 | 0.6 | 0 |
| 2 | | bypass | 1.83 % | 11.7 | 1.8 | 7.2 |

Run-to-run spread for one case is about ±0.5 points: the baseline bypass ran at 1.13 % in a first, discarded pass, then 2.18 % and 1.65 %. Within that noise:
- Learn from me costs nothing measurable. Its poll wakes the app once every 30 s; the steady ~1 wakeup/s is there with it off too.
- The strip, the typing indicator and a 300-message thread stay within P10's open-panel range.

The fixes are for correctness under a lock, not a measurable idle win.

Artifacts are in `build/perf/<timestamp>-perf2-*` (git-ignored). Each holds `summary.json`, a per-second `cpu.csv` and `app.log` with `ZEUS_PERF` and `ZEUS_FRAMES` lines.

## Findings on the suspects

- **The strip's model** is computed in `ConversationView`'s body: `StatusStripState.make` and `jump` filter and sort the cards. That only runs when the body re-evaluates. `AvatarStatusModel.now` is `@ObservationIgnored`, so there is no clock tick. Cases 3a, 3b and 5 show no cost above P10's panel figure.
  - Nothing to fix now. If a future profile shows it, appdev can compute the model once per body: `make` and `jump` currently build `stripCards` and filter the cards twice each.
  - `ZeusStatusStrip` takes a plain `Equatable` model, so a `.equatable()` wrapper is possible. It would also need the `onJump`/`onSkip` closures to be stable, so I didn't add it.
- **The recorder's idle poll** was every 30 s, the minimum this task allows. It already did no work while locked, but its timer kept firing. **Fixed:**
  - `ActivityRecorder` reports lock, sleep, unlock and wake through `onSuspendedChange`.
  - `LearnFromMe` cancels the poll when the Mac locks or sleeps. When it unlocks or wakes, the poll runs one tick and restarts.
  - `LearnFromMe.tickInterval` is 30 s.
- **The recorder's per-event work:** every recorded event re-read and decoded the whole day's file to refresh "What Zeus has recorded". **Fixed:** the event is inserted into the in-memory list in the store's time order, and the file is re-read only when the day changes.
- **Ghost mode** changes only the avatar window's alpha, with one 0.2-s `animator()` change per fade (none under Reduce Motion), scheduled from `AvatarGhostState.nextDeadline`. It adds no layer or timer, and the sprite keeps animating at the normal rate because faded Zeus is still visible.
  - While the console is locked the avatar counts as not visible, which holds it at full opacity. So case 4 measured an unfaded avatar.
  - **Still to do:** an unlocked run of `scripts/perf.sh --ghost 0.3 --seconds 60` (expect alpha 0.3 in `app.log`'s `ZEUS_FRAMES` after about 10 s).

## Still open

- **Visible-desktop acceptance:** the same cases with an unlocked console and awake displays, which needs a person at the Mac. Expected CPU, from the bypass runs: about 2 % closed, about 2 % open.
- **Case 3 as written can't happen.** The strip can't show "Waiting for your answer" together with a typing indicator: the strip follows CONTRACT §7, so assistant activity outranks an open question. It was split into 3a (waiting) and 3b (typing, where the strip shows the activity).

## Reproduce

```sh
scripts/build.sh
export ZEUS_PERF_DIAGNOSTICS=1 ZEUS_FRAME_COUNTER=1   # add ZEUS_PERF_IGNORE_OCCLUSION=1 for the controlled runs
scripts/perf.sh --seconds 60 --label perf2-1-baseline
scripts/perf.sh --seconds 60 --learn --label perf2-2-learn
ZEUS_PERF_PANEL=conversation scripts/perf.sh --seconds 60 --question --label perf2-3a-waiting
ZEUS_PERF_PANEL=conversation ZEUS_PERF_ACTIVITY=thinking scripts/perf.sh --seconds 60 --question --label perf2-3b-typing
scripts/perf.sh --seconds 60 --ghost 0.3 --label perf2-4-ghost
ZEUS_PERF_PANEL=conversation scripts/perf.sh --seconds 60 --history 300 --question --label perf2-5-history300
```

`perf.sh` gained `--seconds`, `--learn`, `--ghost OPACITY` and `--question`. It also writes `wakeups_per_second`, `idle_wakeups_per_second` and `energy_impact` to `summary.json`.
