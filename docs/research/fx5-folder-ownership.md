# FX5: preserve user files in the assistant's folder

## Change

The export manifest now governs file replacement, deletion, and delivery file references. An existing unowned target is adopted only if its SHA-256 equals the intended export bytes. A different file is preserved, excluded from delivery references, and reported with designer-approved relative-path copy. Moving the conflicting file lets the next export write normally. First writes use exclusive rename so a user file arriving between inspection and publication also survives.

Delete Everything, per-ID deletion, and pruning remove only manifest-owned export paths. File removal uses non-recursive unlink; a directory substituted at an owned file path cannot have its contents recursively deleted. Newly created directories and write-temporary paths are recorded in the manifest; only recorded empty directories are removed, bottom-up. Existing directory permissions are left unchanged.

New manifest fields are optional. Older manifests still decode; unknown directories and old unrecorded temporary files are deliberately preserved rather than inferred to be owned from their names. A missing manifest allows identical-byte adoption without claiming unrelated files or directories.

Explicit Notes deletion is unchanged in behavior. Designer commit `c3ec5ae` (adopted as `0509927`) makes its confirmation explicit: everything in Notes is permanently deleted, including files added by the user. The same commit updates Privacy's ownership promises. CONTRACT §13 and the generated README describe manifest-only ownership. Settings now exposes the actionable collision text instead of replacing it with a generic write error.

## Evidence

The original HUNT-P scenario is now `LearningFolderOwnershipTests.existingProjectFilesSurviveEveryDeletion`: pre-existing `Zeus/App/Important.swift`, `Zeus/README.md`, and a personal day-note survive export and all three deletion paths, while the owned export is removed.

The focused folder gate passed **20 tests / 2 suites** (`build/fx5-focused-final.log`). It also covers collision retry, lost-manifest adoption, multiple collisions, created-directory cleanup, recorded temp cleanup, legacy manifests, replacement directories, exclusive first-write publication, writer error recovery, and existing folder export behavior.

`scripts/live.sh --quick --only lm4 --agents claude` passed with **Claude Code 2.1.302**, using only a private tmux socket, disposable HOME, scratch project, localhost model and fixture key. The LM4/LF1 probe now seeds a synthetic pre-existing `Zeus/App/Important.swift`, lets real Claude read and acknowledge the exported digest, then erases learning data. It verifies the owned summary disappears, the user file remains byte-for-byte intact, and a late acknowledgment cannot restore a sent receipt.

Live evidence: `build/live/20261018T015531.641248Z/`, summary `build/fx5-live.log`. The gate's build passed with no new compiler warnings. All probe-owned processes and scratch files were cleaned up.

Scrubbed retained proof: `TestFixtures/live/fx5/ownership.json`.

The final full `scripts/test.sh` passed: **1,142 app tests / 232 suites / 528.282 seconds**, **273 package tests**, **16 release tests** and **11 offline live-gate tests** (`build/fx5-full.log`). This includes the native Settings accessibility regression for the specific collision message. The longer app run was observed building its private P13 Release host; no timeout, assertion or test-process behavior was changed.

Final `scripts/build.sh` passed with no compiler warnings (`build/fx5-build-final.log`; existing simulator/destination diagnostics remain). Public and whitespace checks passed. The heavy slot was released after verification.
