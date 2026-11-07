# W9.5.1 — read-only daily previews (development checkpoint)

Base: W9.4 functionality commit `a3613a63b08fd737bea91d40e6718363115f733b` and checkpoint `79f292c951a705b0d294c0aec2ecf452a02a9e79`.
Branch: `moodiary-v3-w9-5-daily-preview-20261107`.

This increment implements deterministic, read-only daily grouping and recent-three previews inside the native month page. It explicitly does **not** create native Diary projections, mark data synced, migrate old data, write through WebDAV, or claim W9.5/W10 complete.

- Entries grouped by valid `topicId + monthKey + dayKey`; no duplicates.
- Event-time ascending; last 3 chosen then displayed oldest-to-newest.
- Excludes tombstones and monthly summary, fails closed on invalid/mixed inputs.
- Original month editor remains intact; date headers show day count and 3-text preview.
- New tests cover time ordering, calendar validation, duplicate heads, deleted items, stable ties and empty previews.
- Full existing application/HTTP/editor/WebDAV regression retained in CI.
- Version advances to independent development build `2.9.2+100` (not a release).
- W9.4 ARM64 APK remains separately under CI `42386193588` until the build and artifact validations conclude.

Remaining critical W9.5: native Diary projection + local visibility preference and dedicated routing; guard ordinary sync/export against a partial metadata backup. W10: complete structured-entity backup, remote merge and restore validation. **Never** advertise readable-only projection as complete cloud backup.
