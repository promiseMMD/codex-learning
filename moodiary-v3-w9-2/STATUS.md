# Moodiary V3 — W9.2 monthly block HTTP adapter

Continuation of W1–W9.1, based on `0b2eb61f8391f87382e1187d9907b0a117104f51`.
Branch: `moodiary-v3-w9-2-block-api-20261107`.

## Implemented

- Corrected the invalid const factory call that blocked the old-v2 migration test.
- The existing SQLite v4 store now reports revision-ID collisions and a second
  monthly summary as explicit domain conflicts. The schema remains unchanged.
- `GET /api/v3/months/{topicId}/{YYYY-MM}` reads blocks without creating rows.
  `?includeDeleted=true` includes recoverable deletion heads.
- `POST /api/v3/months/{topicId}/{YYYY-MM}/revisions` appends an immutable
  revision. Root creation, CAS edits, tombstones/restoration and month moves
  all use the W9.1 transaction and stable operation/block/revision IDs.
- Authentication, exact Host/Origin, CSRF, byte limits, JSON schema validation
  and session rechecks are required. A grant revoked during body parsing or
  before transaction commit cannot leave partially committed rows.
- Only a visible existing long-term topic can receive these blocks. Ordinary
  Diary contents, existing Beta child records, media and sync are untouched.
- Successful replies say `saved_on_phone` and `syncState: local_only`.
  Topic-level WebSocket invalidation is published after commit.

## Request body

All fields are required, nullable fields must be explicit `null`:

```json
{
  "operationId": "operation-example-001",
  "blockId": "block-example-001",
  "revisionId": "revision-example-001",
  "parentRevisionId": null,
  "kind": "entry",
  "dayKey": "2026-11-07",
  "occurredAtMs": 1794038400000,
  "document": {
    "type": "doc", "attrs": {"v": 2},
    "content": [{"type": "paragraph"}]
  },
  "deleted": false
}
```

For summaries, `kind` is `summary` and `dayKey` is `null`. For edits, provide
the currently read `revisionId` as `parentRevisionId` and fresh operation and
revision IDs. A retry uses the *identical complete request*. Day keys are
explicit topic-calendar dates; the HTTP server never infers them from its
own device timezone. The topic timezone assignment UI remains pending.

HTTP 409 preserves existing content when a parent is stale or an identity is
reused incompatibly. Clients must retain their draft and request a refresh;
they must not automatically resend edits against a newly fetched parent.

## Acceptance gate

CI runs old-v2/v3 migration first, then the complete existing mod regressions,
the new real-file reopen test, real loopback HTTP tests, WebDAV partial-pull
regression and the Android ARM64 build. Rust hooks unused by Dart tests are
temporarily disabled as in upstream quality CI and restored before APK build.

New tests exercise rich-text retention, idempotent replay, CAS conflicts,
revision collision, summary uniqueness, soft deletion, month moves, revoked
sessions during slow upload and before commit, oversized/malformed requests,
unrelated Diary protection, WAL-file close/reopen, durable operation receipts,
full history and foreign-key consistency.

## Verified result — 2026-11-07

- Implementation commit: `9999c5b82e4f242c58aff0beebb85560bd921a03`.
- Full CI: https://github.com/promiseMMD/codex-learning/actions/runs/42371348940 — success.
- W9.1 repair also passed independently: https://github.com/promiseMMD/codex-learning/actions/runs/42370665984.
- PC editor: 8 tests, TypeScript check and production bundle passed.
- Legacy database upgrade: 2 tests (v2/v3 to v4) passed.
- Mobile mod regressions: 68 tests, including 9 real HTTP and 1 WAL-file
  close/reopen test, passed.
- WebDAV regression suite: 63 tests passed.
- Legacy browser save/CAS/in-flight draft checks passed locally and in CI.
- Android ARM64 release build passed. ZIP CRC, app package, native ABI,
  bundled PC assets and the monthly API marker in compiled AOT were checked.
- Package: `cn.yooss.moodiary.v3dev`; Android version `2.9.2+98`.
- APK size: `56,603,006` bytes.
- APK SHA-256: `22dc544e32bcb0aa2d03e36f0e511d16419cf1bd014b45a7413df61ddde2f1f0`.
- APK remains a CI development-signing build. Stable signing and physical
  device acceptance remain pending; replacing an older CI APK is not guaranteed.

## Still pending

- A phone/PC monthly block editor and original Diary projection.
- Safe conversion of historical Alpha/Beta records; no conversion has run.
- WebDAV export/merge/restore and block attachments.
- Topic timezone configuration, locked-screen HyperOS device acceptance,
  stable release signing and final end-to-end data recovery acceptance.

This increment is a development backend, not a finished Moodiary 3.0 release.
