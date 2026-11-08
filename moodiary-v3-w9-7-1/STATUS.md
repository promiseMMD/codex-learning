# Moodiary W9.7.1 | Structured graph archive, verified isolated round-trip

Base: W9.6 archive safety gate, commit `80172ab5c6af6663fafe3bc3d82f7c1d4643f52d`, CI `42430422154` successfully passed.
Branch: `moodiary-v3-w9-7-1-graph-archive-20261108`, developer build `2.9.2+103`.

## Implemented
- Deterministic JSON envelope `moodiary-month-graph` version 1 with SHA-256 checksum.
- Exact lossless export of all **five** SQLite v4 W9 custom tables: month mapping, block rows (including original creation time), all revisions including deletion tombstones, all heads (supports divergent tips), and operation receipts including original idempotency payload hash.
- Read-only source snapshot in a Drift transaction; deterministic sorting; no content flattening.
- Decoder enforces schema/column shapes, size/type constraints, calendar validity, unique IDs, page relations, revision same-block parent references, acyclic revision graph, exact head leaves, and operation fingerprint consistency.
- Test-only restore into an **empty isolated** MoodiaryDatabase, with transaction rollback and readback SHA verification. Restore refuses any pre-existing W9 rows or ordinary Diary rows. No production callers.
- Tests cover full two-month graph/tombstone/summary round-trip; deterministic second export; tampered hash; forged foreign head with recomputed hash; target-not-empty; repeat restore denial; missing schema.
- Retains W9.6 legacy ZIP and WebDAV fail-closed gates unchanged.

## Explicitly not yet supported
- This snapshot does **not** contain the ordinary Topic Diary object or media files referenced from TipTap; it is **not** a complete user backup or a ZIP delivery.
- Do not feed it to the live restore UI. It is not automatically uploaded to WebDAV, and it must not turn on the sync-success state.
- No DailyDiary projection/merge, no old Alpha/Beta migration, no new sqlite columns or schemaVersion changes. No change to existing on-device W9 user data.
- Isolated restore is strictly for verification; production restore requires a complete and atomic archive protocol with topic + media checks, and conflict-safe import.

## Next
W9.7.2: verify archive against a real cloned SQLite snapshot, topic-identity and binary attachment manifests; build full ZIP with per-entry hashes and restore protocol. W9.8: stable (topicId, dayKey) DailyDiary uniqueness and guarded editor routing. W10: multi-device WebDAV convergence.

CI status: code checkpoint; check the actual GitHub Actions run, tests and APK artifact before marking delivery accepted.
