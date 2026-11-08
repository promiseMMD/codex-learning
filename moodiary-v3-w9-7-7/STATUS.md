# W9.7.7.1 — safe, read-only interrupted restore/ZIP quarantine inspection

Branch: `moodiary-v3-w9-7-7-orphan-inspection-20261108`.
Developer version: `2.9.2+109`.
Parent: CI-tiering branch `f2e2b38de844f01567183088feae04714799c325`; reusable full parity run `42453337271` was in progress when branched.

**Why:** An abrupt `kill -9` of the W9.7.5 process bypasses `catch` cleanup, leaving same-parent `.moodiary-w975-*` directories. W9.7.4 ZIP transport can likewise leave `.moodiary-w974-*` temporary ZIPs. Their presence is NOT evidence of a valid recovery; indiscriminate deletion could destroy the only copy of a file being restored.

**Code:**
- `ModMonthOrphanInspectorV1.scanPrivateParent(path)` examines only immediate children of an explicitly supplied, trusted private parent; never recursively reads attachments or touches the running SQLite.
- It recognizes exact W9.7.4 and W9.7.5 hidden-directory naming conventions and the W9.7.5 `restore-state.json` phases.
- Reports `incompleteRestore`, `readyButUnverified`, `invalidRestoreJournal`, `unsafeStagingEntry`, or `unknownArchiveStage`. Every result requires review. A phase of `ready` is NOT trusted without rereading SQLite and media receipts.
- No symlink following, strict metadata byte limits, no traversal beyond the supplied parent, a bounded number of candidate directories, deterministic sorted results. A symlink root fails closed.
- API contains **no cleanup, delete, rename, resume or activation operation**. App UI does not call this API yet. Existing W9.6 archive/WebDAV safety gates remain unchanged.

**Tests:** known states, malformed/missing/forged journals, oversized journals, symlink directory, symlink journal, root symlink, shallow recursion, staging-count limit, preserved original media and no destructive side effects. Data-sensitive fast CI automatically runs these tests; full CI retains all previous W9.7.6 tests.

**Not yet done:** Real Android kill -9/restart, startup integration and explicit owner provenance, private-storage lifecycle, POSIX fsync/parent fsync across filesystems, native-asset runtime verification, safe GC of abandoned quarantines, full production migration and live activation. Those must remain separate gated work. No real-device QA performed.

**Acceptance:** inspect the latest GitHub Actions run on this branch before claiming this checkpoint is green. Complete CI required before integration; APK delivery requires the explicit APK tier.
