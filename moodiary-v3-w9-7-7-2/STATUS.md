# Moodiary 3.0 W9.7.7.2 — REAL Linux SIGKILL crash/reopen test

Baseline: W9.7.7.1 `df1e514d075579d4de116150da26fdf2effdea66`, fast CI `42454017977` success.
Branch: `moodiary-v3-w9-7-7-2-sigkill-recovery-20261108`.
Version: `2.9.2+110`.

## Acceptance target
The previous W9.7.6 tests threw `ModSlotSimulatedProcessDeath`; these did **not** kill a process. This checkpoint adds an independent Dart child that opens an isolated test-only generation slot and is killed with **real Linux SIGKILL** at one of the seven actual writer checkpoints:
1. journal_written
2. files_copied
3. generation_verified
4. directory_moved
5. generation_installed
6. pointer_written
7. journal_committed

The test parent creates two fully isolated, real on-disk SQLite+graph+media datasets, commits an old generation, starts the child process, and waits for a flushed checkpoint signal. It sends `ProcessSignal.sigkill` (the child never enters Dart `catch`/`finally`), then **starts a second independent Dart OS process** for `recover()` and `currentDirectory()`. It checks old version bytes, historical media bytes, new source bytes, pointer-selected version, no incoming temp stage, OS file lock release and idempotent subsequent reopening.

Fast CI runs the representative pair `directory_moved` (not committed) and `pointer_written` (committed). Full CI runs **all seven phases** via `MOODIARY_CRASH_MATRIX=full`. Flutter tests skip process kill on non-Linux platforms. All test files are new and isolated from app production storage. Neither W9.6 backup/WebDAV protection nor app restore paths are modified.

The existing W9.7.7.1 orphan inspector remains read-only, with no automatic cleanup or activation.

## Critical boundaries
- A real SIGKILL is **not** a hardware power loss, filesystem journal loss, directory fsync verification, Android LMK or Android reboot. All latter requirements are still OPEN.
- `File.flush` and atomic rename do not imply parent-directory durability on real flash storage; production recovery must get proper directory fsync, especially on Android. Do not claim power-loss guarantees.
- Tests use Flutter's Linux runner, a Dart SDK executable and per-test systemTemp. They do not require device permissions. They never attach to a running app DB, cloud or user folders.
- App UI and live restore are still intentionally disabled.

## Next
- Obtain a green sensitive fast CI run and confirm real child PID is killed (no exception injection).
- Explicit `[full-ci]` integration regression on the exact commit before merging.
- After this, implement durable fsync API with explicit platform support checks and real Android process kill/restart harness, staged before any live user restore.

## Test-runner isolation correction
The first two harness attempts started a child from within `flutter test` and hung before Dart `main()`; the startup executable caused an error initially, then no output in the Flutter test runtime. **Do not claim they proved SIGKILL safety.** The new harness is a **standalone Dart CI command** outside the Flutter test runner. Fast CI runs two kill boundaries, complete CI all seven. This avoids Flutter tool startup-lock interference. The Flutter unit tests remain unchanged and separately run. A green latest CI run is required before making any Linux process-recovery claim.
