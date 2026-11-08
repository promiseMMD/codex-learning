# Moodiary W9.7.8.4 — Nutstore WebDAV directory completeness
Based on 0b70b20aabf697c8ba53691bfb31c11235dff848 on 2026-11-08.

## Changes
- Count raw PROPFIND XML response elements BEFORE filtering href-less rows; stop at the Nutstore 750-item threshold.
- Fail closed for Nutstore malformed multistatus envelope, missing href, or out-of-root href.
- Fail closed if an already-discovered child directory returns HTTP 404; retain valid empty-root first-use behavior.
- Keep third-party WebDAV behavior unchanged except the child-404 safety correction.
- Add Rust unit and local HTTP-server integration tests; run all Rust WebDAV tests under full CI.

## Still unfinished
- Real Nutstore pagination, request quotas/backoff, official-account certification, Android phone tests and production APK sign-off.
- No cloud deletes, automatic retry of ambiguous PUT/DELETE, or backup restore auto-activation.

## Validation
- Commit requests fast plus full CI using [full-ci] on the same SHA; only CI output, not this document, proves pass/failure.