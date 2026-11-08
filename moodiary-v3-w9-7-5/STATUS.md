# Moodiary 3.0 — W9.7.5 isolated full-native + W9 SQLite + media restore

**Parent baseline:** W9.7.4 `11552587493a21939d2d46a543743d68c808b8ba`, GitHub Actions `42444593327` SUCCESS; ARM64 artifact id `13602939331`.
**Current branch:** `moodiary-v3-w9-7-5-isolated-full-restore-20261108`.
**Developer version:** `2.9.2+107`.

## What code is present
- A new explicit API `ModMonthIsolatedRestoreV1.restoreZipToNewIsolatedDirectory` that **refuses any pre-existing target**. Uses ZIP central directory preflight and an isolated, already SHA-verified extraction directory from W9.7.4.
- Creates a **brand-new SQLite database** in a same-parent hidden staging directory; first restores all W9 month graph tables via the W9.7.1 isolated-DB graph restore routine, including historic revisions, heads, operation receipts and tombstones.
- Strictly inserts native Diary, Category, Place and deleted-entity tombstone records, with existing business IDs, UTC microsecond timestamps, media arrays, tags, rich-content-derived link edges and non-mutating status values. Uses real DB transactions for native inserts, never replacing an existing Diary ID. Tombstones have empty pushed-backend receipts, never claim cloud sync.
- Streams all media from the isolated verified input into another new local media directory. Rehashes each copied media file against the complete ZIP SHA-256 manifest, then reopens the SQLite file on disk and validates its native/structured rows through the actual repositories. SQLite foreign-key and integrity checks are required.
- A minimal phase journal (`restore-state.json`) marks `created`, `graph_restored`, `native_restored`, `media_restored`, `readback_complete`, and `ready`. Test-only failure checkpoints allow exhaustive interruption injection at each phase. A caught failure cleans its own private staging directory without touching source archive or target directory.
- Only after all verification succeeds, discards the temporary full ZIP extraction and renames the **new isolated database+media directory** into a previously absent destination on the same filesystem.

## Acceptance cases
Real ZIP and original LocalArchive layout; two ordinary Diary objects including the Topic; category, place, native tombstone; a two-month cross-month move of one block, an older media-bearing revision, soft deletion of later revision, monthly summary and operation IDs; media copy SHA verification; reopening physical SQLite, counts and exact graph readback. Fault injection at all six checkpoints, pre-existing target survival, tampered ZIP, and second restore refusing replacement.

## Critical limitations (do not claim shipping)
- This is **an isolated recoverability proof, not an in-place user restore**. It does not open or replace the app's currently running database. There is no crash-safe atomic promotion/rollback of an existing LIVE DB and its media; merely renaming a fresh isolated directory is not the same thing. W9.6 legacy ZIP and WebDAV protections remain in force.
- The phase journal is diagnostic: unexpected process death can leave a quarantined directory. A safe startup orphan discovery/resume/cleanup policy, snapshot locking and a transaction coordinator for real user data still need engineering.
- Production APK must still be checked in Android 16 / HyperOS 3; Dart unit tests use test-only ZIP transport because Rust-native assets are disabled for Flutter tests. No direct release-signing compatibility or migration guarantee.
- Full backup is not encrypted, and specific ZIP64 central-directory ranges still fail closed. No automatic cloud synchronization has been enabled.

## Next work
W9.7.6 restore planning + crash-safe multi-object activation/recovery journal with rollback and reproducible kill/restart simulation. Follow with W9.8 DailyDiary native projection, W10 WebDAV conflict-safe sync. Only then consider exposing backup/restore in UI after device QA.

**CI state:** source is a checkpoint; inspect latest Actions run. Do not claim W9.7.5 success or APK until completed.
