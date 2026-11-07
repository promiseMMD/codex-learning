# Moodiary 3.0 — W8 LAN image intake (isolated development)

**Branch:** `moodiary-v3-w8-media-validation-20261107`

**Status:** standalone pre-upload image validation policy implemented and CI smoke tested. The real upload endpoint and MediaManager integration are **not yet implemented**.

## Frozen media security contract

The user-approved PC first release supports inserting images into ordinary diaries and long-term monthly blocks. The phone remains the owner of all media files and WebDAV credentials. HTTP is only permitted on trusted private WLAN after phone approval; it provides **no transmission encryption**.

Upload flow for the next implementation phase:

1. Browser checks image size and MIME before issuing authenticated same-origin upload. Never include session credentials in query strings, localStorage or a remote CDN.
2. Phone verifies pairing, CSRF and request origin. Limit concurrent uploads, refuse missing/oversized Content-Length, enforce actual byte count during streaming.
3. Write incoming data to a private temporary file; never trust the incoming filename as a path.
4. Verify actual signature and decoded dimensions (PNG/JPEG/WebP), reject corrupt and decompression-bomb content, calculate SHA-256 over persisted bytes.
5. Reuse Moodiary `MediaManager.saveImage(XFile(tempPath), reuseExisting:false)`, **only after** verification; ensure the temporary file path does not begin `image-` to prevent bypassing native reuse logic.
6. Return an internal media ID rather than an Android path. Stage an attachment reference in the editor and upload only one authorized account session.
7. Commit the diary JSON and media reference together with its authoritative revision check. Failed CAS must retain user draft and make unused media eligible for safe orphan cleanup.
8. WebDAV sync must preserve the image bytes and content references, and restore must verify hash and media existence before declaring completion.

## Current code

- `overlay/mobile/lib/app/home/mod_lan_image_policy.dart`: <=20MiB stream accounting; declared MIME/actual signature agreement; PNG dimensions; JPEG/PNG/WebP support only.
- `tests/image_policy_smoke.dart`: truncated, overlength, mismatched, disguised executable, PNG dimensions and chunk-boundary regression.
- `.github/workflows/moodiary-v3-w8-policy.yml`: standalone Dart test gate without patching the real app.

The signature check is a **preliminary filter**, not an image decoder or AV scanner. It must never be used as evidence that an uploaded file is valid, safe to render or durably linked.

## Release-blocking W8 work

- Install image policy into the real W7 Android build after W7 CI gates are green.
- Implement authenticated streaming upload/GET with robust content-type handling and cache prevention.
- Create decode, SHA-256, atomic media attach and cleanup logic using the native media subsystem.
- Expand the W6 schema to allow safe image nodes only when their media IDs exist and belong to the local library.
- Integrate PC Tiptap upload button, drag/drop and paste through server-sourced media IDs.
- Simulate interrupted uploads, high memory pressure, simultaneous edits and full WebDAV backup/restore on real devices.

Until these are complete, **no W8 HTTP upload API is active**. Existing official app and legacy diary data remain unchanged.
