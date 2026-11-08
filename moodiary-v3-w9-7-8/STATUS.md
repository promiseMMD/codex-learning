# Moodiary 3.0 W9.7.8 — Nutstore-specific WebDAV safety

Parent: 591491661e750f34732c7b5ed09f882b8dcc22d8. Date: 2026-11-08.
Official configuration: https://dav.jianguoyun.com/dav/ ; account email and an app-specific third-party password.
Official published constraints: 500M default per-file upload; 600 requests/30min free, 1500 paid;
single WebDAV listing page may contain at most 750 entries and requires pagination.
Implemented in the existing WebDAV backend (not a second sync engine):
1. Strict official host/HTTPS /dav/ URL guard (also in settings UI) and nonempty app password.
2. Fail-closed listing when Rust listObjects returns 750+ entries because the API exposes no
   complete-pagination indicator. We DO NOT infer that a truncated listing is complete.
3. Conservative preflight 500M byte limit before writeObject or writeObjectFile.
4. Standard/non-Nutstore WebDAV endpoints remain unaffected.
5. Unit tests for host lookalike, cleartext URL, userinfo, query, listing boundary and upload boundary.
Unfinished: Rust HTTP-level per-request throttling and paged PROPFIND; genuine Nutstore account
certification with test-only directory; 429/503 retry policy; real Android and power-loss tests.
Do not auto-retry ambiguous PUT/DELETE, delete cloud folders, or treat a partial listing as success.
Source: https://help.jianguoyun.com/?p=2064