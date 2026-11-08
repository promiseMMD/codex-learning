# W9.8.1 — SQLite v5 daily mapping groundwork

2026-11-08, based on previous W9.7.8.4 green CI commit 0eac8ef.

## Implemented
- Adds `mod_day_pages` with unique `(topic_id, day_key)`, unique nullable native Diary ID, local-only visible flag, and creation time. Referential protection prohibits deleting a bound native Diary.
- Upgrades v4→v5 without touching old `diaries` and monthly revision data; fresh installs and reset are handled.
- `ModDayMap` only materializes a day index after validating an active, unconflicted monthly entry head. Repeated calls are idempotent; invalid dates, summaries and tombstones fail closed.
- Local-only visibility persists separately from `diaries.show`; no automatic conversion or ordinary Diary editing.
- Existing legacy ZIP/WebDAV safety gate now checks the daily table. W9 GraphV1 also refuses an export/restore if any daily mapping exists, because format v1 cannot serialize it.
- Adds SQLite tests and Fast/Full CI routing; developer build number +111.

## Not yet implemented
- Actual native DailyDiary creation/projection, default ordinary-list placement, last-three preview and exclusive edit route; no claim this staging change is visible in the app.
- New archive V2 including day map, full media backup/restore, cloud merge, real-device testing and signed release.
- Nutstore compatibility is explicitly paused per user request; no Nutstore-specific code changed in W9.8.1.

## Required validation
- Green Fast and Full CI, migration tests from v2 and v3, check existing v4 database later with explicit fixture.
- No automatic user-data upgrade is permitted in an Android release build until migration and recovery are validated.