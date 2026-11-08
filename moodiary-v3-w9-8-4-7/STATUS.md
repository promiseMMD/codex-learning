# W9.8.4.7 — Canonical preview/slot isolation gate

## Completed code changes (pending CI acceptance)
- Added a canonical-path preflight before any ZIP extraction into a preview.
- Reject previews nested inside the immutable V2 recovery slot or aliased into it through a symlinked parent.
- Reject an unresolved/nonexistent preview parent without changing slot contents.
- Existing refusal for pre-existing preview paths stays intact.
- No production database, media, or WebDAV activation; scope remains isolated/test-only.
- New three-case regression suite; retains all W9.8.4.4–6 regression tests.
- App development build number: 2.9.2+120.

## Security notes
- Uses resolved canonical parent/slot roots. It is a preflight isolation guard, not a defense against a concurrent privileged process replacing paths during the operation.
- Before enabling actual on-device restore, enforce an app-owned private root, ensure directory ownership/handles survive concurrent mutation, perform real-device backup/restore and repeatability tests, and verify all app data formats including media.
- Fast + Full CI on the final commit are mandatory acceptance criteria. The test-only API is not a released restore feature.

## Remaining delivery gates
Production restore integration, full WebDAV W9 graph protocol, offline merge/conflicts, native daily Diary projection, drafts, media/UI, old data migration, timezone/search, signing and upgrade validation, two-device/HyperOS testing, release candidate.
