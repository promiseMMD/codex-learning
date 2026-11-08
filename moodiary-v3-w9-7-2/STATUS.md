# Moodiary W9.7.2 — Native + W9 verified staging manifest

Starting baseline: W9.7.1 successful CI `42433418765`, commit `9c969414dcc2e0082c01c886b9f06d69e9f14bd8`.
Branch: `moodiary-v3-w9-7-2-manifest-20261108`. Development version: `2.9.2+104`.

## This increment implements

A **staging-only** deterministic closure manifest, separate from production sync and restore. Native content comes from the existing legacy archive layout (`LocalArchive.writeArchive`), accompanied by the W9.7.1 structured graph `structured/month-graph.json`.

Validation:
- Every active native diary/category/place object listed in the legacy manifest must have its exact object payload; deleted entries may not retain a payload. Stray unindexed native entities are rejected.
- Every distinct `topic_id` in the W9 graph must resolve to a present and visible native Diary. The caller MUST apply the same topic identity predicate used by `ModDiary.isTopic`; presence of a matching UUID is not sufficient.
- Every non-null month binding `diary_id` must have its original native Diary payload.
- Native Diary arrays and derived TipTap/markdown media references are cross-checked against legacy manifest media and staged bytes.
- Every image/audio/video/attachment reference in **every historical W9 revision** must be staged, even if not referred to by the native Diary. Unsupported media node kinds with `attrs.src` are rejected.
- All staged file paths are validated against explicit allowed families; no path traversal, surprise directories, unbounded entry counts or oversized in-memory staging.
- SHA-256 + exact byte lengths of all staged objects, including binary media, are recorded in a canonical manifest. A bundle digest covers its own metadata; any tampered/missing/extra staged content invalidates the original manifest.

Regression includes an actual `LocalArchive.writeArchive` collector with file-backed image, synthetic graph with historical media, tamper, missing media, unsafe path, unrecognized nodes, wrong Topic predicate, missing bound Diary, and nonmutating validation.

## Safety boundary

**Not a production full backup yet.** Staged media is held in memory for deterministic unit testing (256 MiB safety limit); a streamed write-to-temp, per-entry readback and atomic ZIP promotion are still required for large real libraries. No live WebDAV or ZIP routing is changed. W9.6 safety gate continues blocking incomplete cloud/ZIP operations. No on-device migration, user data mutation, or DailyDiary projection.

## Next

1. Stream/chunk media to a quarantined filesystem staging directory and lock source snapshot before hashing.
2. Build a real ZIP with both legacy objects and graph; verify ZIP central directory, manifest and each payload before publish.
3. Restore into a separate database and media directory, re-open, validate full graph and native Diary references, then design a transactional promotion/recovery journal. Only then expose restore or unblock WebDAV.

CI status: This document is a checkpoint, not a claim of final APK acceptance. Check successful Actions job and artifact.
