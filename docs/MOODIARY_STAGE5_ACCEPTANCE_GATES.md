# Moodiary Stage 5 — fixed acceptance gates (execution record)

This is a **test and release gate record**, not a change to
`docs/MOODIARY_MOD_PROJECT_SPEC_V1.0.md`. That specification remains authoritative.
No gate below authorizes production ModMonth synchronization, APK signing or
release, or changes to official/user data.

Baseline: `b612fabf3adeeb4a411ae8b8dcc2639d73480b96` on
`moodiary-v3-w9-8-4-31-permanent-application-id-20261110`.
Verified run: https://github.com/promiseMMD/codex-learning/actions/runs/43272161993
Fast: success. Full Acceptance: success. Seven-checkpoint SIGKILL matrix:
success. Signed/unsigned APK jobs: skipped. No Android device evidence.

## Gate A — isolated verified candidate ZIP publication

- [x] Linux verified ZIP generation, SHA-256 and media validation (CI).
- [x] Linux no-clobber concurrent publication and destination collision (CI).
- [x] Linux pre/post hard-link SIGKILL boundary (CI).
- [x] Linux abandoned partial staging ZIP ignored on retries (CI).
- [ ] **Actual process SIGKILL during complete candidate assembly**, then
      restart and verify no final partial ZIP, no remote mutations, and no
      overwrite of pre-existing destination.
- [ ] **Android compatibility**: production code calls
      `Process.run('link', [source, target])` in
      `overlay/packages/feature/moodiary_sync/lib/src/data/mod_month_remote_chunked_candidate_v1.dart`.
      Linux CI does **not** establish that Android exposes this executable,
      nor that the destination storage permits hard links. Test on Android
      internal app storage and user-selected storage separately.
- [ ] If Android hard-link publication is unavailable, design and validate
      an atomic no-clobber replacement; **never** fall back to streaming into
      the final path or replacing an existing file. Fail closed until verified.

Close Gate A only with actual Android test evidence and complete-build crash
evidence. Do not infer Android success from `Platform.isAndroid` or Linux CI.

## Gate B — WebDAV reliability

- [ ] Nutstore live test with a **separate, disposable test directory** and
      disposable credentials; never use the official App's remote directory.
- [ ] Verify conditional create/update and stale-version rejection against
      actual server responses (including ETag behavior).
- [ ] Test disconnect, timeout, retry, duplicate requests, partial download,
      and concurrent writer; verify remote history and media hashes.
- [ ] Confirm no production sync entry is enabled before Gate B and C pass.

## Gate C — two-device history consistency

- [ ] Validate revisions, operations, tombstones, date mapping and media hashes
      after alternating edits, offline changes and reconnection.
- [ ] Test conflicts and deterministic retries using isolated test data.
- [ ] No automatic merge with the official App or migration of old mod test
      data as a prerequisite.

## Gate D — integration and delivery

- [ ] Only after Gates A–C: separately review production entry integration.
- [ ] Android device test: backup/restore, migrations, app co-installation,
      upgrade, media and user settings.
- [ ] Persistent signer continuity and versionCode checks before any approved
      release. CI success alone is not device or delivery acceptance.

## Batch execution rule

Group related source changes and regression tests per gate. Before commit,
check dependencies, imports, formatting and focused tests where an SDK is
available; then run Fast followed by Full Acceptance once per coherent batch.
On failure fix the batch rather than add a new unrelated test. Close a gate
only on its evidence, not on a subjective percentage. Keep production sync
safety gates unchanged.
