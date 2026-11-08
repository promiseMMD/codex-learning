# Moodiary W9.7.6 — crash-recoverable isolated generations (non-production)

**Parent baseline:** W9.7.5 `f36b8122ea04a1e68cc9482aa48686f3e63c98c2`, CI `42447186581` **success**, ARM64 artifact `13605021065`.
**Branch:** `moodiary-v3-w9-7-6-recovery-slot-20261108`.
**Developer version:** `2.9.2+108`.

## Implemented scope

- Added `ModMonthRecoverySlotV1.createNew()` which **requires the slot root not exist**. Validated isolated-only identity marker. Existing app/database directories or arbitrary user folders are rejected; no production call site.
- Immutable, numbered **generations**: one directory contains the same SQLite and media snapshot. Previous generation stays untouched, even after activation of a new verified generation.
- Sorted file receipts with streaming SHA-256, size, path allowlist and no-follow symlink refusal. `generation-proof.json` is self-checksummed, includes W9 graph snapshot checksum and required restored SQLite and phase-ready status. Open DB on disk to run SQLite integrity and foreign-key checks and graph validation before any pointer switch.
- A fixed-size `recovery-journal.json` records old/new and phase. Per-file `.next` plus flush-and-rename commits state. The pointer `active.json` is **the single commit boundary**, referencing the new immutable DB+media generation by ID and manifest hash. No in-place copy of running SQLite or existing media is performed.
- On independent reopen, `recover()` examines journal + actual active pointer: old pointer means abandon only uncommitted staged generation, preserve the old one; valid new pointer means confirm commit. If the newly committed generation becomes invalid and the old one remains valid, switch the pointer to old and retain the invalid new directory for examination. Invalid journal, broken old data, tampering or unexpected paths fail closed.
- Tests simulate immediate process death without catch cleanup after 7 distinct write checkpoints and reopen a new slot instance: before/after copy, proof, directory rename, pointer write and journal commit. Also first-install crash, corrupted new media rollback, preserved older generations, symlink/path traversal, strict empty slot root and idempotent restart.
- Runs ordinary/editor/HTTP, old v2-v3 migrations, W9.7.1 graph, W9.7.2 closure, W9.7.3 stream, W9.7.4 ZIP, W9.7.5 SQLite+media and W9.7.6 pointer recovery regressions before Android ARM64 compile.

## Critical engineering boundary

This is an **isolated preview generation slot** and uses synthetic process-death injection plus reopening in tests. It is NOT actual Android kill -9 or device reboot testing. There is no safe live-database+media shutdown/activation integration; thus never describe this as a released restore. An actual Android production launcher needs:
- exclusive app process shutdown / DB WAL checkpoint, no open writers, generation roots under private app storage and verified pointer reads by every consumer;
- correct fsync of parent directories (flush and rename alone is not a guaranteed durable crash-transaction across all filesystems);
- recovery on real device after process kill/restart and Android lock-screen/OS low storage events;
- encryption for user archive and full W9 backup/snapshot capture consistency;
- orphan cleanup policy for abandoned W9.7.5 staged directories and logs.

W9.6 legacy ZIP/WebDAV safety gates remain intact. No existing real user data is modified, migrated or claimed synced.

## Next
Check GitHub Actions acceptance for this branch. If passed, W9.7.7 native integration sandbox (including real process crash, fsync parent support, startup orphan analysis and read-only restore preview); then W9.8 DailyDiary projection, W10 WebDAV conflict-safe sync.
