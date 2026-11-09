# W9.8.4.11 Technical Design and Acceptance

## 1. Goal
Expose the W9.8.4.10 non-mutating V2 recovery inventory inside Android Settings → Storage without enabling any operation that changes recovery copies or live diary data.

## 2. Layering
1. UI: `RecoveryInventoryPanel` renders the overview, entries, status and read-only detail sheet.
2. State: `recoveryInventoryProvider` asynchronously loads a snapshot and supports invalidation/retry.
3. Inventory: existing `ModMonthRestoreInventoryV2.inspect` remains the sole enumerator and classifier.
4. Root: W9.8.4.9 Android private-root binding remains the only source of the production Application Support path.

## 3. Non-creating root inspection
Add `ModMonthPrivateRestoreRootV2.openExistingIfPresentForSupport` and `ModMonthAndroidPrivateRestoreV2.openExistingRootIfPresent`.
- Resolve only the already-initialized Android Application Support path.
- Inspect the reserved child using `FileSystemEntity.type(..., followLinks: false)`.
- Return null only when the child is genuinely absent.
- If a file, link, forged marker or non-canonical directory occupies the path, fail closed.
- Never call `createOrOpenForSupport`, `createNewWorkspace`, `recover()` or any writer from the UI path.

## 4. UI behavior
- Android only; non-Android builds do not render the panel.
- Missing root or empty inventory: show an explicit empty state; do not create a directory.
- Entries show state, measured bytes and file count when available.
- Null measurements remain “unknown”; never display them as 0 B.
- Tap opens a detail sheet containing state explanation, path, measured size and file count.
- A rescan invalidates the provider. An error shows a retry affordance and does not modify files.
- The panel explicitly states that its bytes are already included in Storage → Other.

## 5. Data and accounting
Do not modify `StorageScanner`, `StorageReport`, category colors, reclaimable candidates or cleanup selection. The panel is a breakdown of a subset already counted under “Other”, not a new top-level storage bucket. Never add inventory bytes to the main total.

## 6. Forbidden behavior
No delete, purge, prune, repair, journal reconciliation, restore activation, live database import, media replacement, or reset-all integration. No action button may be presented for those operations.

## 7. Acceptance matrix
| Area | Test | Expected |
|---|---|---|
| Root | Missing reserved root | null result; no directory created |
| Root | Existing verified root | opens exact canonical root |
| Root | Symlink alias | rejected; target and link preserved |
| Inventory | empty / ready / recoveryRequired / needsReview / unrecognized | distinct UI states |
| Measurement | null size/count | “unknown”, never zero |
| Accounting | inventory displayed | no change to StorageScanner totals |
| UI | entry tap | read-only details only |
| UI | refresh | new snapshot replaces old result |
| UI | read error | retry available; bytes unchanged |
| Safety | all UI states | no delete/repair/live-restore controls |
| Regression | existing storage and recovery suites | remain green |

## 8. CI
- Fast CI: format, root-path safety tests, recovery panel widget tests, existing data-sensitive recovery suite.
- Full CI: same tests plus complete migration, archive, WebDAV, SIGKILL and browser regressions.
- APK build is not part of this feature commit. A later explicit APK tier is required for delivery.
- Physical Android/HyperOS 3 verification remains a separate human/device acceptance gate.
