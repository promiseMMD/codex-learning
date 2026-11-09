# W9.8.4.15 — Full-fidelity backup and migration design

## User-approved migration contract

The selected policy is A: preserve as much as possible of the complete W9 history.
The old app is an immutable source and must not be uninstalled, overwritten,
cleared, migrated in place, or otherwise modified.

The migration payload must preserve:

- all five mod_month_* tables, including every revision and parent link;
- every mod_month_heads row, including divergent heads if present;
- every mod_month_ops row, operation ID, payload hash and applied timestamp;
- revision deletion/tombstone flags, including historical deleted revisions;
- all mod_day_pages rows, local visibility flags, creation timestamps and
  native Diary bindings;
- mod_month_pages.diary_id bindings;
- native Diary/category/place records, native tombstones and all referenced
  native and historical revision media;
- original record timestamps where the upstream restore API permits it.

A current-head snapshot is not a substitute. If an input package lacks the
revision or operation history, the migration must fail closed and report that
the source is incomplete. It must never label a partial snapshot as a complete
migration.

## Architecture

### Export

1. Acquire Moodiary's existing sync-exclusive lock.
2. Capture native entities, tombstones and the W9 graph under one database
   transaction so the SQLite snapshot is internally consistent.
3. Stream the upstream LocalArchive.writeArchive objects into the existing W9
   private staging sink.
4. Add the checksummed V2 month/day graph envelope.
5. Seal the receipt manifest. Verify native topic identity using the exact
   ModDiary.isTopic rule (__moodiary_mod_topic_v1), native Diary closure, day
   Diary bindings, and all historical media references.
6. Build a ZIP in quarantine, extract it into a second quarantine, re-hash
   every file and compare the manifest, then publish only to an absent path.

### Import

1. Hash the selected ZIP and bind a persistent migration journal to that exact
   source SHA-256. A different ZIP cannot resume a partially completed import.
2. Verify ZIP preflight, all receipt hashes, native closure, month graph,
   day mappings, native Diary bindings and historical media before any live
   database write.
3. Require a fresh destination: no existing diaries, W9 graph/day rows or
   tombstones. Existing old app data is never addressed by this code path.
4. Restore native Diary/category/place records using a migration-only policy
   that preserves source timestamps. Preserve native tombstones explicitly.
5. Restore all W9 tables and day mappings in one SQLite transaction, inserting
   parent revisions before descendants and verifying all native Diary
   references before writing.
6. Verify SQLite integrity, foreign keys, row counts, exact graph readback,
   native entity IDs, tombstones and SHA-256 of every restored media file.
7. Persist the completed journal only after all checks pass. The same source
   ZIP can resume after interruption; a different source cannot silently merge
   into a partially migrated target.

### Safety boundaries

- No writes to the old package or its private database.
- No delete, repair, activate or live-restore action is added to the existing
  read-only recovery inventory.
- No WebDAV/LAN sync format is changed by this local migration.
- The ordinary ZIP without structured/month-day-graph-v2.json is not accepted
  as a full-fidelity W9 migration package.
- APK publication remains blocked until migration tests and release gates pass.

## Important source-access limitation

The currently installed cn.yooss.moodiary.v3dev build cannot be updated in
place because its signing private key is unavailable. The old LAN month API
exposes topics and current month snapshots, not the full revision DAG or
mod_month_ops. Therefore the new full-backup implementation can guarantee
complete backups from builds containing W9.8.4.15 onward, but it cannot
retroactively extract hidden SQLite revision/operation rows from the already
installed old APK through that API.

A complete migration from that installed build requires a legitimate full
source export from the old app (or a user-supplied, verified SQLite database
copy in addition to its media/native backup). Until such a source is available,
do not claim that the current installed app has been fully migrated. Keep it
installed and unchanged.

## Acceptance tests

- Round-trip every row and value in all six custom tables.
- Preserve original revision IDs, parent chains, heads, operation IDs and
  payload hashes; preserve all deleted values.
- Preserve every day mapping and both month/day native Diary bindings.
- Reject dangling or duplicate native Diary bindings.
- Reject missing native topic diaries and missing historical media.
- Reject malformed/tampered ZIPs before any live write.
- Reject a non-empty target and reject a different ZIP when a journal exists.
- Simulate interruption after native import and after graph commit; resume only
  from the same ZIP and verify idempotence.
- Verify timestamps, native tombstones, all media hashes and database
  integrity/foreign keys after import.
- Run Full CI on the exact candidate SHA; then install in parallel on Xiaomi
  14 Pro / HyperOS 3 without touching the old app.
