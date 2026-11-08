# Moodiary W9.8.3 — structured daily Graph V2 (isolated only)
Base W9.8.2 SHA 0d80c54f20059e679a3c9c60b7e3cf4139e0778e; verified Fast/Full CI.

Implemented:
- Deterministic SHA-256-protected full W9 month graph (all revisions, heads, tombstones and ops) plus complete daily map (topic/day, visibility and creation timestamp).
- Rejects invalid calendar days, duplicate/reordered/orphan mappings, mismatched historical revisions, altered nested V1 graph, and forged metadata even with recomputed outer digest.
- Refuses any native Diary binding since this structured-only graph does not contain native Diary bytes or media.
- Single-transaction export, isolated empty-database restore, re-export/readback comparison, and atomic rollback.
- V1 archive export remains fail-closed with day rows. Old production backup, ZIP, WebDAV and sync gates remain unchanged.
- Fast and Full CI include regression tests. Dev app build number is 2.9.2+113.

NOT production-ready:
- This V2 graph does NOT contain native Diaries, attachments, media, preferences, or the full app backup package.
- NO live restore, no WebDAV activation, no automatic native Diary projection/feed unification, and no APK produced.
- Nutstore-specific compatibility development remains paused.

Next gate: integrate native+V2 graph+all media into a verified full archive and crash-safe isolated promotion, then guarded native daily Diary projection. Android physical device QA still required.