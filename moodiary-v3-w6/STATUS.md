# Moodiary 3.0 W6: Tiptap JSON safe-write boundary

Status: source committed; CI and Android APK verification required.

## What is implemented
- An independent rich-document protocol for authenticated, phone-paired LAN sessions.
- POST /api/rich/diaries and GET/PUT /api/rich/diaries/{id}.
- Strict schema-v2 validation: text paragraphs, headings, hard breaks, bold/italic/underline/strike/code marks and safe http(s)/mailto links.
- Unknown schema versions, media/attachments, custom nodes, unsupported attributes, scripts and over-limit JSON are rejected, never flattened.
- Atomic insert-if-absent and compare-and-swap update using the shared DiaryRepository.
- Client-supplied revision is mandatory for edits; title and rich text are persisted through the native Diary model.
- Date/month topic records remain read-only pending real monthly block persistence and conflict-aware WebDAV.
- W6 Flutter tests cover validation, replay/idempotency, CAS conflicts, and failed edit preservation.
- Existing W5 browser stays a cautious text-only editor. W6 does **not** mean browser Tiptap UI or photo upload has shipped.

## Verification
CI: .github/workflows/moodiary-v3-lan-w1.yml.
A CI green result would establish compilation/unit-test and APK build success, not Android real-device or two-client rich-edit acceptance.

## Next critical tasks
1. Build a browser TipTap editor using the upstream native schema extensions and connect to W6 API with correct revision handling.
2. Implement transactional uploaded-media storage and attachment hashes with true device restore.
3. Persist month-bound topics/blocks and monthly summary without destructive single-document rewriting.
4. Verify WebDAV offline/online multi-device reconciliation, corruption aborts, migration and rollback.
5. Perform first-connect phone confirmation, Android lockscreen, rate-limit/security, and actual 2-device tests.
