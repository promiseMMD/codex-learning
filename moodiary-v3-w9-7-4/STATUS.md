# Moodiary W9.7.4 — ZIP quarantine and verified readback

**Parent baseline**: W9.7.3 `1f3dba09da307b62a50972cc3f942a7e1575bdb5`, successful GitHub Actions `42440985142`, ARM64 artifact `13602810803`.
**This branch**: `moodiary-v3-w9-7-4-zip-isolation-20261108`, version `2.9.2+106`.

## Current code

- Added `ModMonthZipPreflightV1.inspect()`: bound-check the ZIP end-of-central-directory record and central file headers **before extraction**. Strict allowlist for ordinary Diary/category/place, complete W9 graph, media and verification manifest. Rejects duplicate paths, traversal, symlinks/special entries, unsupported compressed media, encrypted ZIP, oversized metadata, ZIP bombs, multi-disk archives, malformed directory and unsupported ZIP64 directory offsets. Handles ZIP64 per-file size extensions.
- Added `ModMonthZipBundleV1.createVerified()`: consumes a validated W9.7.3 sealed directory, writes ZIP with existing Rust `fast_zip` to private same-parent quarantine, inspects ZIP central directory, extracts to another isolated temp directory, checks each extracted payload using W9.7.3 full SHA-256 closure, then rechecks the source and publishes ZIP via same-parent rename to an absent target.
- Added `ModMonthZipBundleV1.extractVerifiedIntoIsolatedDirectory()`: for tests and later full-restore construction ONLY, requires absent target, preflights ZIP, extracts into a new temp directory, verifies full manifest/graph/Diary/media closure and publishes the verified isolated directory. No live Diary, SQLite, or media library writes.
- Added injectable `ModMonthZipTransportV1`: production uses Rust `fast_zip`; CI uses an **actual** ZIP file via Python stdlib with stored-media behavior. This is purposeful because Flutter/Rust binary hooks are disabled during ordinary Dart tests. Distinguish actual ZIP format and safety tests from native-codec Android device verification.
- Tests: ZIP round-trip of genuine native LocalArchive and W9 graph; extracted byte identity; metadata and media tamper; corrupt/truncated ZIP; duplicate paths; traversal; symlink central metadata; compressed metadata bomb; forbidden compressed media; ZIP64 per-file header; target collision, and no source alteration.

## Still not a complete backup / restore

- This is **a quarantined ZIP module with independent verification**. User-facing backup, WebDAV and live restore remain guarded by W9.6. No production call path enables the new methods, and no database migration is triggered.
- Import still does not restore into isolated native database + W9 SQLite + attachment directory with one atomic commit and recovery journal. That is W9.7.5 and must be accepted before any user-facing release.
- Security scope: preflight rejects unsupported ZIP64 **central-directory offsets and counts**, supports ZIP64 **per-file size fields**, limits total expanded bytes. If a future archive exceeds that limit, fail closed rather than making false backup claims. A hostile filesystem can race destination creation; the current rename is intended for app-private cooperative storage, not a no-overwrite atomic syscall.
- The current ZIP is **not encrypted**; don't distribute it as a protected cloud backup. Privacy/encryption, concurrent snapshot consistency and Android 16 device acceptance must be handled before exposing a backup UI.

## Next
Finish latest CI, verify ARM64 packaging. W9.7.5: separate DB/native/structured/media restore, rollback journal and actual interrupted-restore testing. Then DailyDiary W9.8, WebDAV W10 after correct convergence.
