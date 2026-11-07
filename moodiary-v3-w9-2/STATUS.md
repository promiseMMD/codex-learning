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
full history and foreign-key consistency. CI results are pending at commit.

## Still pending

- A phone/PC monthly block editor and original Diary projection.
- Safe conversion of historical Alpha/Beta records; no conversion has run.
- WebDAV export/merge/restore and block attachments.
- Topic timezone configuration, locked-screen HyperOS device acceptance,
  stable release signing and final end-to-end data recovery acceptance.

This increment is a development backend, not a finished Moodiary 3.0 release.
