# W9.8.4.1 — Full-closure V2 staging (not production restore)

Base: W9.8.3 commit 5a884f97c93f70c9184004e9575041d97ed34561 (Fast + Full success).

## Actual implementation
- Added `ModMonthVerifiedManifestV2`: one deterministic SHA-256 manifest covering native Diary/category/place objects and tombstones, every W9 historical revision, GraphV2 day map/hidden state, and all referenced image/audio/video/attachment media.
- Validates V2 graph and nested V1 graph hashes, then passes the verified nested graph to the EXISTING audited V1 native+media closure validator. A legacy-only structured graph cannot silently replace the V2 file.
- Supports streamed media receipts (size and SHA-256) without loading large media into memory; caps object counts, metadata, individual media and total bytes.
- Added `ModMonthStreamStageV2`: private quarantine directory, streaming write and readback, detects mutation/symlink/duplicate/path traversal, fully verifies published directory, then publishes by rename only if destination is absent.
- Added unit/real LocalArchive regression tests for missing historical media, ordinary Diary missing media, source tampering, V2 envelope corruption, unsafe path and previously existing output.
- Version bump to 2.9.2+114. Fast and Full CI both exercise V2 manifest and stream stage tests.

## Deliberately not activated
- V2 ZIP export, ZIP64 handling, real isolated V2 full restore and crash-safe two-generation slot promotion are **not** provided here; existing V1 ZIP and restore paths remain isolated and fail closed.
- No production backup, Android automatic restore, native Diary materialization or ordinary-feed merging; no WebDAV / Nutstore compatibility changes.
- This is a prerequisite for W9.8.4.2: ZIP V2 and cold V2 full-database/media recovery, then recovery-slot proof and SIGKILL; no user data migration before those tests are complete.

## Acceptance
- Only exact HEAD Fast CI + Full CI success establishes baseline. Actual Android APK and physical device tests are separate.