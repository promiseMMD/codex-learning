# Moodiary 3.0 — W8.4 authenticated HTTP image staging

**Branch:** `moodiary-v3-w8-staged-http-20261107`. Derived from W8 native staging branch without replacing W7 or public releases.

## Implemented

- Adds `POST /api/media/staged` to the existing phone-only HTTP listener.
- Request is accepted **only after** normal same-origin / Host checks, a valid phone-approved session Cookie, and `x-moodiary-csrf` matching the session token.
- Request body is raw binary image data (no multipart and no attacker-chosen path), with declared image Content-Type and Content-Length.
- Hard per-image limit 20 MiB; a streaming byte count checks declared vs actual length; 30-second inactivity timeout on request stream.
- Existing W8 policy verifies JPEG/PNG/WebP magic bytes, PNG/WebP container limits, and image decoder verifies content with bounded decoded dimensions.
- The request file goes into Moodiary's **application-private cache**; its SHA-256 is computed from staged bytes.
- Successful response includes temporary `stagingId`, bytes, MIME, SHA-256, expiration and explicit `state: staged_not_attached`. It is NOT a diary write acknowledgment.
- Revoking the paired browser invalidates staging ownership and attempts to clear its temporary files; server restart clears only this owned cache directory.
- Existing W6 document validator keeps all media nodes read-only/rejected. No media can be silently inserted into a diary, and the new route never writes to the database.
- Rich editor remains unchanged until the next atomic attach protocol is proved correct.

## Request/response example

Request from an *already approved same-origin browser*:
```http
POST /api/media/staged HTTP/1.1
Origin: http://192.168.1.2:11220
Content-Type: image/png
Content-Length: 175233
X-Moodiary-CSRF: <short-lived value returned by /api/session>
Cookie: moodiary_lan=<session cookie>

<raw PNG bytes>
```

Response:
```json
{
  "state": "staged_not_attached",
  "stagingId": "48-lowercase-hex-character temporary nonce",
  "sha256": "...",
  "size": 175233,
  "mime": "image/png",
  "expiresAt": "2026-11-07T..."
}
```

Session cookies / nonces are examples, never literal values or log output.

## Must-pass tests

1. A browser without pairing: 401, no staging files.
2. A paired browser without matching CSRF: 403, no staging files.
3. Wrong Host / Origin: 403, no staging files.
4. Missing or forged MIME: 415; missing length: 411; large size: 413.
5. Truncated/malformed JPEG/PNG/WebP: decoder or header policy rejects, with temp files deleted.
6. Concurrent uploads capped at 2 and pending items at 8.
7. Revoked session cannot complete a new staging response; old stage must become unusable.
8. Active upload terminated by network drop, user stop, phone process exit: no official diary changes.
9. No success status is presented as local diary save or WebDAV sync.
10. Flutter build, native image decoder regression, W7 and WebDAV regression must pass.

## Release blockers

- Stage-to-permanent `MediaManager.saveImage` promotion with durable hash verification.
- Exact native Tiptap image schema and authenticated image retrieval route.
- CAS-protected transactional attachment to ordinary diary without overwriting another edit.
- Multi-image inserts, drag/drop and paste UI, cancellation and orphan cleanup.
- Month-block persistence and WebDAV restore, including missing/changed image repair.
- Android phone + desktop end-to-end security and screen-off testing.

**W8.4 is an internal integration milestone**, not a user-ready photo editing feature. No production diary or cloud migration is performed by this code.
