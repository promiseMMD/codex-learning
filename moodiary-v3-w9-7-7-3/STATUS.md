# Moodiary 3.0 — W9.7.7.3 CI handoff & safety-gate recovery
Date: 2026-11-08. Branch: `moodiary-v3-w9-7-7-3-ci-handoff-20261108`.
Parent: W9.7.7.2 `b4adba609afa4b214d704e9ae4a3082dba6a46e8`.
## Verified before this change
- W9.7.7.2 fast run 42457479402 passed at 07:11 UTC.
- That run skipped "Focused SQLite and WebDAV safety regressions" and "Real SIGKILL cross-process recovery" because the commit edited only a workflow YAML file; **this is NOT a successful SIGKILL acceptance**.
- Prior data-sensitive run 42456754684 failed inside an older `flutter test`-nested SIGKILL test. The new standalone Dart runner existed later but had not been exercised on the latest green YAML-only commit.
- Earlier full regression 42453337271 passed on the previous CI tiering code, not W9.7.7.2.
## Changes
- In `.github/workflows/moodiary-v3-fast-ci.yml`, treat changes under `.github/workflows/` or `moodiary-ci/` as sensitive to **both data and editor**; run focused recovery, real standalone SIGKILL, migration and editor tests.
- In `moodiary-ci/check-gates.py`, add a regression contract that rejects CI workflows accidentally dropping this self-change risk routing.
- No app SQLite, WebDAV, restore, UI, media, or source overlay changes. No new APK.
## Required acceptance before merge
1. This branch's fast CI must PASS with the *sensitive* steps run (not skipped), including independent OS SIGKILL.
2. The exact-commit explicit `[full-ci]` parity path must PASS, including all seven SIGKILL boundaries.
3. Keep Android power-loss/fsync and real-device QA marked OPEN; a Linux SIGKILL does not establish flash durability.
4. Avoid merging to main or exposing user-facing live restore before those separate protections and device tests.
