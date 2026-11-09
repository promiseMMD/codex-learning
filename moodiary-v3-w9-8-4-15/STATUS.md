# W9.8.4.15 — Full-fidelity migration

## Confirmed

- User selected policy A: preserve all month revisions, operations, deletion
  flags, date mappings and native Diary bindings; old app remains untouched.
- The exact upstream topic classifier has been inspected:
  ModDiary.isTopic(d) => d.tags.contains('__moodiary_mod_topic_v1').
- W9.8.4.14 latest-upstream Fast CI passed on commit
  71c6728bd7946351c21ca0fdcedd7911770323ae.
- Existing V2 graph archive already serializes the five month tables and
  mod_day_pages, including revision/operation history and deletion flags.
- Existing V2 verified ZIP stage already supports streamed native objects,
  large media, SHA-256 receipts and ZIP extract/readback validation.
- Existing V1 closure validator already verifies native topic Diary records,
  month page Diary bindings and historical revision media.
- Existing import primitives are test-only and isolated; no production
  full-fidelity migration path is connected yet.

## Implementation work in this stage

1. Extend V2 graph validation to support native Diary bindings only when those
   Diary IDs are present in the same full archive.
2. Add a production empty-target graph restore method with a single transaction,
   parent-first revision insertion and exact readback.
3. Extend V2 verified manifest to validate daily Diary bindings against the
   native Diary manifest.
4. Add a migration-only native restore policy that preserves source timestamps.
5. Connect the full native + W9 graph + media bundle to the user backup export
   and import workflow, with source-SHA journal/resume and readback checks.
6. Add regression, tamper, crash-resume and full round-trip tests.

## Critical limitation

The installed v3dev app cannot receive this new exporter as an in-place update
because the old signing private key is unavailable. Its current LAN API does
not expose all revisions or operation rows. A new v3safe APK cannot read the
old package's private SQLite database. A full migration from the installed
build therefore remains blocked until a complete source export or verified
database copy is obtained. No partial snapshot will be presented as complete.

## Release gates

- Fast CI and Full Acceptance CI pass on the exact W9.8.4.15 candidate.
- Full archive round-trip passes all native + custom graph + media assertions.
- Interruption/resume and tamper tests pass.
- User supplies a full source package for the currently installed old build,
  or confirms that it contains no W9 data requiring historical recovery.
- Persistent signing key and Actions secrets configured.
- Signed ARM64 APK and Xiaomi 14 Pro / HyperOS 3 device acceptance pass.


## 2026-11-09 repair verification

- Commit 26efbfe repaired the corrupted duplicated Dart source
  mod_month_graph_archive_v2.dart by rebuilding it from the previously
  passing W9.8.4.14 baseline, retaining the production migration method.
- Commit 88b5b10 fixed the brittle LocalArchive.importDirectory Python
  patch anchor, so it adapts safely to the prepared method signature.
- Fast CI run 42589617826 passed all steps on 88b5b10, including exact
  source preparation, editor/LAN tests, SQLite/WebDAV regressions,
  SIGKILL cross-process recovery and older-database migration checks.
- This does not certify the new full archive export/import end-to-end.
  Full CI is required next. Signing and release remain fail-closed.
- Old v3dev package and user data were not accessed or modified.

## Stabilization-only phase (2026-11-09)

Scope frozen. No new diary, LAN, WebDAV, recovery-inventory, or editor features.
The original `cn.yooss.moodiary.v3dev` installation and all user data remain untouched.

- Restore legacy ordinary ZIP import to its original `LocalArchive.import`
  and `RestorePolicy` branch.
- Route archives containing both full-history markers to the strict V2
  importer; reject incomplete marker pairs instead of silently downgrading.
- Add an explicit test importing the production W9.8.4.15 backup service so
  Full CI must compile that code, rather than skipping it.
- Follow-up tests still required: real legacy ZIP, full V2 ZIP, full-fidelity
  round-trip of six tables, hashes, tombstones and interrupted import.
- This is a test candidate, not a release or an approved migration of the
  previously installed old app. The release-readiness gate stays closed.
