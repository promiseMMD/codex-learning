# Moodiary W9.8.4.4 — ZIP-to-generation end-to-end integration

Base W9.8.4.3 commit 948675af4d6de9667abe5b06340336d3015b2d03 (Fast and Full green).

## Scope
- One developer-only operation composes V2 ZIP preflight/extraction, cold SQLite+native+GraphV2+media restore, and the V2 two-generation recovery slot.
- A fresh preview directory is required; pre-existing paths are refused.
- Slot independently verifies/copies the restored snapshot and atomically promotes its generation pointer.
- Preview is deleted after slot copy; slot retains the immutable generation.
- Test asserts native daily mappings, revision history, historical media and active generation readback.
- Existing V1/V2 isolated recovery suites and V2 SIGKILL suites remain in CI.
- Dev version 2.9.2+117.

## Safety boundary
- Developer-only isolated workflow. It does not point at the running app database/media.
- No production restore UI, no main merge, no APK, no Nutstore/WebDAV changes, no device QA.
- Failures before promotion leave the old active generation selected; the preview is cleaned if it was successfully published.
