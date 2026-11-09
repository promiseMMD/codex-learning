# W9.8.4.8 — Application-support-root isolated V2 recovery workspace

## Goal
Introduce a dedicated private recovery workspace API that derives fresh preview and slot paths from one verified parent. This is a developer-only adapter for a **caller-supplied** application-support directory. It does not itself verify Android UID ownership, and it does not activate restore into a live app database.

## Implementation
- Require the supplied parent to exist as a normal directory; explicitly reject symlinked parent paths.
- Allocate a new, unguessable child directory through Dart createTemp; never accept a user-selected workspace name during creation.
- Write and check an isolated workspace identity marker, then create a V2 generation slot inside it.
- On restart, allow reopening only a marked, canonical direct child of the supplied root.
- Derive preview path from the workspace; reject already-existing foreign preview content.
- Reject non-regular archive paths and archives located inside the workspace.
- Expose isolated install, verified current generation read, and explicit restart recovery; never open or promote a live diary database.
- No recursive workspace removal on setup failure. Unsafe bytes remain for inspection.

## Tests
1. Install full V2 ZIP and reopen verified generation; preserve unrelated user file.
2. Reject symlinked application-support root.
3. Reject forged workspace identity before any restore.
4. Reject existing foreign preview, preserving its contents.
5. Reject an archive placed in the workspace.
6. Reject reopening an unrelated directory.

## Required gates
- Same existing V1/V2 ZIP, SIGKILL, SQLite, editor, and WebDAV regression suites plus the new six cases in Fast and Full CI.
- No change to Nutstore provider compatibility.
- No APK release; Android application-support-root binding and physical-device QA still pending.
- No main merge or production restore UI.
- Developer build version: 2.9.2+121.

## Known limitations
The passed-in root is only a trust assumption until wired to Android's application-private support directory. Canonical path preflight and owner markers are not defenses against privileged concurrent filesystem substitution. Production use requires Android-specific root binding, concurrency hardening, device restoration, and full backup verification.
