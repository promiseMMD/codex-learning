# W9.8.4.11 — Read-only isolated recovery inventory UI

## Scope locked
- Android-only panel under Settings → Storage.
- Read-only listing, measured size/file count, state, path details and manual-review guidance.
- No delete, purge, repair, journal recovery, activation or restore-to-live-database operation.
- Existing storage totals/categories remain unchanged; recovery bytes are a detail already included in “Other”.
- Missing private root is an empty result. Opening Storage must never create a root or workspace.
- Non-Android builds do not show the Android-only panel.

## Implementation
- Add `openExistingIfPresentForSupport()` and Android facade `openExistingRootIfPresent()`; both are non-creating.
- Add a FutureProvider that reads the verified root and delegates to the W9.8.4.10 inventory engine.
- Add an isolated recovery inventory panel with refresh, summary, status rows and read-only detail sheet.
- Keep the existing StorageScanner, reclaimable list and cleanup selection untouched.
- Developer version: `2.9.2+124`.

## Acceptance
- Missing root: null/empty result and no directory creation.
- Symlink root: rejected without following it or modifying target bytes.
- Existing verified root: inventory can open only that root.
- Empty, ready, recoveryRequired, needsReview and unrecognized states display distinctly.
- Unknown sizes remain unknown; no zero-byte substitution.
- Capacity details are not added to the main storage total a second time.
- Read-only details expose no delete, repair or live-restore controls.
- Refresh replaces the prior provider result; failures can be retried.
- Existing storage cleanup, sync, migration, V1/V2 archive, SIGKILL and WebDAV tests remain mandatory.
- Run Fast CI and Full Acceptance on the exact final commit SHA.

## Explicitly deferred
- Free-space probing and restore-capacity reservation.
- Manual deletion/quarantine or retention decisions.
- Journal repair, generation activation and live diary/media replacement.
- Android instrumentation and physical HyperOS 3 validation.
- APK build and release signing.

## Safety notes
- Inventory is an advisory snapshot, not a race-free deletion authorization.
- A measured size is not proof that the content is semantically valid.
- No automatic reset-all claim may ignore isolated recovery copies.
- Linux CI does not prove Android private-directory ownership or HyperOS 3 behavior.
