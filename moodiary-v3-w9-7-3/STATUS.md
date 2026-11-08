# Moodiary 3.0 — W9.7.3 streaming quarantine, verification and atomic directory publication

**Baseline:** W9.7.2 verified build `2.9.2+104`, commit `ec7afeb63036d0be9cf9f0c0d31711ab3b0f774d`; GitHub Actions run `42436926615` succeeded and uploaded an ARM64 artifact.

**Branch:** `moodiary-v3-w9-7-3-stream-stage-20261108`. Developer build `2.9.2+105`.

## Implemented, no app backup UI

1. W9.7.2 verified manifest logic now also accepts **independent per-file (size, SHA-256) receipts** plus the small native diary/manifest/graph JSON. The original <=256 MiB in-memory method remains for its regression tests and gives the same deterministic envelope for small libraries. The streaming method never loads media files into RAM.
2. New `ModMonthStreamStageV1` implements the existing `ArchiveSink` API. The legacy LocalArchive writer can write native objects and stream media into a private quarantine directory; then add `structured/month-graph.json`. W9.6 blocking remains unchanged.
3. Strict path allowlisting shared with W9.7.2, regular-file checks, symlink denial, no duplicate path overwrite, bounded metadata memory, private partial files, per-file SHA readback and best-effort change-during-copy detection.
4. Fail-closed `publish()`: scans and rehashes every persisted payload, validates all real Topic/native/graph media dependencies, writes a deterministic `verified-bundle.json`, independently verifies readback, then renames the isolated temp directory to a previously absent target **on the same filesystem**. Failed validation removes only the private staging directory and leaves pre-existing targets intact.
5. Separate read-only `verifyPublished()`: after publication, reject modified payloads, unexpected file entries, missing files, links and invalid graph/entity/media associations.
6. Tests cover actual LocalArchive writer integration, byte-identical manifest for small sets, sparse >256 MiB video, tampering before/after publish, invalid topic, path traversal, duplicate files, source and embedded symlinks, injected entries, destination collision and abort-after-publish.

## Safety limits and explicit non-goals

- This delivers **a verified local DIRECTORY staging primitive**, not a complete ZIP backup, a portable restore, or a new end-user feature.
- For future production use, a synchronized snapshot boundary across ordinary Diary/media/W9 SQLite revisions is still required; size+mtime change detection is only a best-effort safety signal, not an atomic snapshot guarantee.
- A crash-safe ZIP writer, ZIP readback, isolated full-native+graph+media restore, cross-file commit/recovery journal, and Android 16 / HyperOS 3 device validation are still **not implemented**.
- Filesystem directory rename is atomic on a single filesystem under expected cooperative app conditions; do not claim protection against hostile filesystem races or arbitrary concurrent mutation.
- W9.6 legacy ZIP and cloud synchronization safety gates remain in force with structured data. No existing diary migration or overwrite, no false cloud-success acknowledgment.
- New code is initially only a test-facing library entry point. Do not label the APK stable until CI and later real-device acceptance finish.

## Next

W9.7.4: deterministic streaming ZIP from verified directory; ZIP central-directory, per-entry digest and path-allowlist readback; quarantine extraction and isolated verification **without touching live SQLite**. Then W9.7.5 complete full-native+structured+media restore and crash recovery. Only after acceptance move to W9.8 DailyDiary projection and W10 WebDAV conflict merge.
