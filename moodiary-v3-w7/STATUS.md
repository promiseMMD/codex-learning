# Moodiary 3.0 — W7 React + Tiptap LAN Editor

Status: implementation committed; CI is the authority for verification. Experimental, **not a complete Moodiary 3.0 release**.

## Product baseline (fixed)

- User-approved trusted private LAN HTTP + manual phone confirmation.
- Android foreground service continues under ordinary screen lock.
- Phone is sole durable writer and owner of WebDAV credentials.
- PC/mobile saved changes notify automatically via authenticated WebSocket.
- Topic/month: one canonical Diary per topic-month, independently revisioned blocks and optional collapsed monthly summary.
- No last-writer-wins for block conflicts; no destructive legacy migration.

## W7 code

- The PC editor is an independent React 19/Tiptap 3 application, sourced from `web/` and built using the pinned upstream editor dependencies.
- It is bundled into Flutter assets `mobile/assets/lan`, served at `/lan-editor/` **only after an authorized session**.
- It uses the W6 JSON endpoints for creating, opening and version-checked updating *supported simple rich documents*. The W5 text-only editor remains available separately.
- Documents are limited to v2 paragraphs, headings, bold/italic/underline/strike/code, hard breaks, and href-only safe links. Unknown nodes/mark attributes, media, and legacy format remain read-only.
- Browser saves to the phone with strict CAS revisions, 2-second delayed autosave, `Ctrl+S`, and visible unsaved/error/conflict state.
- WebSocket events refresh the list and check the phone revision before invalidating a dirty draft. The browser does not claim the phone's local save means WebDAV sync succeeded.
- The frontend avoids persistent personal diary storage, remote CDNs, and external JavaScript URLs.

## Verification required

1. `corepack pnpm exec tsc --project lan/tsconfig.json --noEmit`.
2. `corepack pnpm exec vitest run lan/src/w7.test.ts` using a real Tiptap editor.
3. `corepack pnpm exec vite build --config lan/vite.config.ts` and emitted asset checks.
4. Flutter tests for W6 rich API/W5 safe text editor/W3 events/W2 ledger.
5. WebDAV regression tests and signed Android v3dev APK build.
6. Real two-device test: initial pairing, screen-off, browser reload, simultaneous updates, session revoke, zero data loss.

## Not yet implemented

- Full upstream Moodiary extension kit; current compatibility is a verified safe subset.
- PC image upload, in-editor media node rendering and backup restoration.
- Production per-topic monthly Diary and independently persisted Block/Summary revisions.
- WebDAV per-block multi-device merge and non-destructive legacy migration.
- Production signing and end-to-end real-device acceptance.

Never use real irreplaceable notes or production WebDAV folder with this development APK before safety acceptance.
