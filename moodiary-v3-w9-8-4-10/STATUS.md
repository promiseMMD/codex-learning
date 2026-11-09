# W9.8.4.10 — Read-only inventory and safe retention of V2 recovery copies

## Changes
- New strictly non-mutating `ModMonthRestoreInventoryV2.inspect` that accepts an identity-verified Android recovery root.
- Enumerate each immediate root entry with no symlink following; foreign files, links and unmarked workspaces remain visible as `unrecognized` or `needsReview`.
- Recognize `empty`, `ready`, `recoveryRequired`, `needsReview`, and `unrecognized` states without calling `recover()`, modifying active pointers, or deleting any bytes.
- Report known file counts/sizes only for verified, bounded scans, with a 50,000-entry and 256-GiB measurement cap. Exceeding the bound, encountering links or reading invalid data fails closed to `needsReview`.
- Explicitly flag every nonempty inventory as `requiresExplicitRetentionDecision`; an automatic “clear all app data” claim must not silently ignore these isolated recovery copies.
- V1/V2 ZIP, SQLite and WebDAV protocols remain untouched; no production restore UI, cleanup action, archive mutation, or APK.
- Developer version `2.9.2+123`.

## Acceptance
Eight new cases: no-workspace baseline, successful immutable V2 generation, unfinished recovery journal, foreign user file, symlink alias, corrupt workspace marker, unexpected preview, and unknown file in marked workspace. Existing W9.8.4.2–9 ZIP and SIGKILL tests remain.
Run Fast and Full CI on the exact final SHA.

## Deferred
- Actual Android disk free-space query and extraction capacity reservation, which cannot be inferred from file size alone. A future trusted platform-backed free-space probe must fail closed on missing data and enforce a conservatively sized restore budget.
- Product UX for preview/explicit retention, reset-all handling, quarantine and manual deletion, concurrency on physical devices.
- Restore activation, full WebDAV Graph V2 exchange, multi-device merge and stable signing.
- Nutstore-specific compatibility and physical HyperOS 3 testing.

## Safety
The inventory is a read-only advisory snapshot and must never be treated as a race-free authorization to delete. It does not validate Android UID/SELinux ownership; the platform binding is separately enforced by W9.8.4.9. Do not claim production delivery from Linux CI alone.
