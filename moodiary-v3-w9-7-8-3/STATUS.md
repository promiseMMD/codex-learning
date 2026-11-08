# Moodiary W9.7.8.3 — Nutstore page-level WebDAV safety

Parent: ef630fa4c1c57625f5372b96adadf080f9e47e75. 2026-11-08.
Rust DavClient::list_objects uses PROPFIND Depth:1 recursively.
Nutstore's official 750 maximum applies per directory listing response,
not per whole archive. This code refuses to process any Nutstore response
with >=750 entries because the Rust client exposes no verified page token.
Keep legacy Dart total-count guard as conservative defense in depth until
per-directory pagination is implemented and tested against an official account.
Rust unit tests verify 749 vs 750 threshold, generic WebDAV and lookalike host.
Complete CI now explicitly runs this Rust test with Rust 1.95; daily CI stays Dart-only.
NO remote deletes or silent pagination heuristics; NO real Nutstore credentials used.
Remaining: official server pagination mechanism, quota/backoff, Android device QA.