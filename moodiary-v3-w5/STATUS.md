# Moodiary V3 W5 · LAN editor draft-safety hardening

Base: `promiseMMD/codex-learning` branch `moodiary-v3-monthly-lan-dev-20261107`.

This step is deliberately narrow. It protects user edits while the W4 LAN writer is still text-only. **It does not claim to implement full Tiptap, photo upload, real monthly Diary persistence, or WebDAV block-level merge.**

## Confirmed product baseline

- A long-term topic has one logical monthly diary with independently addressable event blocks.
- Dates are collapsible; the most recent recorded day opens by default; in-day blocks sort ascending.
- Monthly summary is optional and collapsed by default; normal diary feed shows monthly diaries unless locally disabled.
- Android foreground LAN service, trusted-private-LAN HTTP, manual phone pairing.
- Browser can create/edit notes, upload pictures in the planned full release, and receive saved changes immediately.
- Phone remains the authority for local durable writes; WebDAV sync is independent and conflict-safe.
- No user-facing internal tags, no silent migration, no destructive LWW overwrite.

## W5 changes implemented

1. `apply_w5.py`: exact-anchor patch after W4 overlay. The step fails closed if upstream changes unexpectedly.
2. Browser edit generation counter; in-flight save acknowledgment cannot mark newer text as saved.
3. Deferred autosave after 2 seconds of inactivity; edits typed while a save is in progress trigger another guarded save.
4. Stop note switching during pending writes; ignore stale asynchronous open responses.
5. On write failure preserve unsaved status; maintain read-only guard on rich or unsupported documents.
6. `browser_race.test.cjs`: end-to-end mocked browser regression for save races and read-only protection.

## Local verification

- `python3 apply_w5.py <W4-overlay-root>`: passed against frozen W4 source overlay.
- `node --check extracted-web.js`: passed.
- W4 browser create/save/conflict smoke test with W5 output: passed.
- W5 save-in-flight → edit → next CAS autosave regression: passed.
- W5 unsupported-complex-note read-only regression: passed.

GitHub Actions runs the same browser tests before Flutter unit tests and Android build. **No W5 APK should be presented as verified until this CI run finishes successfully.**

## Outstanding P0 dependencies

- Android real-device pairing and screen-off service reliability.
- Real Tiptap JSON round-trip, media upload and attachment integrity.
- Production monthly storage, per-block revision/tombstone durable writes and migration.
- Cloud/WebDAV replay, concurrent edit conflict preservation, multi-device restoration and destructive-operation audits.
- Stable APK signing and upgrade compatibility.

## Explicit safety boundaries

This milestone retains W4's existing restrictions: ordinary simple-text Diary writes only, all rich/media/monthly entries read-only. W5 should never be described as fully bidirectional rich-text editing or as a finished Moodiary 3.0 release.
