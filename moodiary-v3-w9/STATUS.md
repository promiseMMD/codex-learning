# Moodiary V3 — W9.1 durable monthly blocks (schema v4)

Development branch: `moodiary-v3-w9-month-store-20261107`.

## Baseline retained

- W1–W8.5 implementations and behavior remain intact.
- Existing `diaries`, `diary_media`, `tombstones`, `DiaryRepository`,
  Tiptap editor and WebDAV engine are **not replaced or rewritten**.
- One logical visible Diary per `(topicId, YYYY-MM)` is the final design.
- Independent block identities/revisions, optional one-summary-per-month, and
  same-day chronological records continue to use the agreed W2 model.
- Persisting local block history does **not** itself mean the WebDAV engine
  knows how to transport these custom tables. It does not yet.

## W9.1 implementation

- Schema **v4** additive custom tables:
  `mod_month_pages` maps topic+month to at most one canonical existing Diary.
  `mod_month_blocks` keeps stable block IDs and enforces a unique summary.
  `mod_month_revisions` stores immutable revisions including tombstones.
  `mod_month_heads` supports future multi-head divergence explicitly.
  `mod_month_ops` stores SHA-256 operation fingerprints for replay safety.
- Fresh installs create W9 tables in the same existing SQLite connection;
  upgrades from v1/v2 run original generated migrations through v3 before
  W9 table creation, and upgrades from v3 add only the W9 tables.
- Full database reset includes these custom tables (not Drift-generated).
- Local writes use a Drift transaction around block creation, revision,
  head-pointer update and operation receipt. No silent LWW on an old revision.
- Month moves preserve the original block ID and its history.
- A deleted block remains as a tombstone until an explicit next revision.
- New monthly entry creation only accepts a strict **safe subset** of Tiptap
  JSON; unsupported historic or media-rich documents are never modified.

## Explicitly NOT completed

- No automatic migration of existing ordinary Diary or older Beta records.
- No automatic creation/projection of the canonical month Diary body.
- No phone UI nor PC Web API connected to W9 yet.
- No WebDAV block serialization, merge or restoration.
- No photo media nodes in the W9 editor; unsupported content is protected.
- No claim of real device data preservation until migration/rollback tests.

## CI acceptance

1. Flutter fresh SQLite v4 test, month uniqueness and retained normal Diary.
2. Different blocks in same month, one summary, chronological list.
3. Revision CAS, idempotent op retry, op ID collision, stale rejection.
4. Tombstone, cross-month move, bad date and invalid doc protection.
5. Whole-app reset cleans the W9 custom tables.
6. All existing W7/W8.5 and WebDAV regression and Android build.
7. **Before release:** v3-file-to-v4 schema upgrade fixture,
   W2 ledger/DB roundtrip and WebDAV old+new format compatibility.

## W8.5.1 safe media recovery next

The previous W8.5 media code has runtime rollback but process crashes can
leave orphan media. Extend using a durable, operation-ID-keyed journal with
PREPARED → PROMOTED → ATTACHED → VERIFIED states; mark recovery only after
validating both native media bytes and the Diary reference in SQLite. Never
delete an arbitrary name from old user data; delete only files allocated and
owned by the operation.
