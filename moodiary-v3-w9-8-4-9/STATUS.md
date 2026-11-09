# W9.8.4.9 — Android app-private V2 recovery root binding

## Delivered implementation
- Source of the Android application-support directory is the existing initialized `PlatformService.get().applicationSupportPath`, backed by the upstream `path_provider` Android implementation. The production facade takes **no caller-supplied root path**.
- Android-only gate refuses use outside Android and refuses calls before platform bootstrap.
- Reserve a fixed `.moodiary-v2-private-recovery` child of the application-support directory. Verify regular directory, canonical location and exact strict versioned identity before any recovery operation.
- Never reuse an arbitrary existing unmarked directory, accept a symlinked root, or follow a caller-selected path into live databases or media.
- Fresh workspaces are allocated only within this checked root. Opening an existing workspace also enforces that checked root and the original W9.8.4.8 owner markers.
- No recursive deletion of unmarked or corrupt folders. No production database, media, WebDAV, backup-route, or UI activation.
- Developer version: `2.9.2+122`.

## Regression acceptance (Fast and Full CI)
Eight new cases: isolated real V2 ZIP install/reopen preserving a live-database sentinel; repeated root creation yields independent workspaces; foreign unmarked root; symlinked root; forged root identity; external workspace reopen; missing root reopen without creation; non-Android runtime rejection. Retain all V1/V2 SQLite/ZIP/slot, WebDAV, Android app/PC UI and real SIGKILL recovery tests.

## Still required before any shipping
1. Android real-device instrumentation: verify root directory permissions, actual Android path, process restart, update and reset behavior on HyperOS 3.
2. Account for real-device storage pressure, concurrent restoration, protected cleanup, power interruption and resumption.
3. Explicit user preview/consent, verified full-data readback, generation activation transaction and crash-safe rollback, **before** touching any existing Diary or media.
4. W9 structured WebDAV full protocol, native day projection, cross-device conflict flow, migration and release signing/QA.

## Scope limitations
Filesystem canonical-path/marker validation is not an inode-handle, SELinux or UID-bound attestation and is not a fully privileged-adversary race defense. Linux CI verifies directory logic only; Android ownership and permission behavior cannot be confirmed without a real device. The adapter is deliberately **not called from the application UI**.
