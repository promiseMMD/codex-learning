# W9.8.4.6 — Restore Preview Ownership Guard

## Goal
Make deletion of an isolated ZIP recovery preview fail closed if the directory has been replaced, linked, or changed by anything outside the current restore. The scope is **test-only isolated generation installation**, not live app data restoration.

## Implementation
- Check a strict V2 restore-state marker and allow only regular, recognized SQLite/media payload entries.
- Capture a per-file receipt (path, size, modified and changed timestamps) before calling the handoff checkpoint or slot installer.
- Recheck before disposal, rename to a private same-parent quarantine, recheck again, then recursively delete only the verified quarantined preview.
- On an unsafe preview, raise `preview_cleanup_unsafe` and preserve the files for inspection; do not blindly recursively delete.
- A receipt and file-stat check protects against accidental changes, not a fully privileged adversarial concurrent writer. Production exposure still requires Android storage isolation and device acceptance.

## Regression tests
1. Newly inserted foreign user file survives a failed restore handoff.
2. A symlink swapped in for the preview never deletes its target.
3. Modified media before cleanup is preserved and reported unsafe.
4. Existing W9.8.4.4/5 success, refusal, rollback and commit tests remain part of Fast/Full CI.

## Deferred
No production restore UI, no live SQLite/media writes, no WebDAV provider changes, no APK shipping, and no merge to main.

## Version
2.9.2+119
