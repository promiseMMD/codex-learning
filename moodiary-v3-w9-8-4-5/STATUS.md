# W9.8.4.5 — ZIP to Generation Slot failure-path acceptance

## Scope
Extend the existing V2 ZIP cold-restore integration suite with five failure-path tests. The tests remain isolated under the temporary test sandbox and do not open or modify live application storage.

## Acceptance coverage
1. Refuse an existing preview directory without modifying its contents.
2. Delete a completed preview when the restore-to-slot handoff checkpoint fails.
3. Recover a simulated process death after slot payload copy by rolling back to the previous generation.
4. Recover a simulated process death after the active pointer write by committing the new generation while retaining the previous generation.
5. Reject duplicate generation IDs without overwriting the existing generation.

## Safety boundaries
- No user-facing restore route is enabled.
- No live app database or media directory is opened.
- No WebDAV/Nutstore compatibility work is included.
- Fast CI and Full CI must both execute the existing mod_month_isolated_restore_v2_test.dart suite.
- APK generation and main merge remain separate delivery decisions.

## Version
2.9.2+118
