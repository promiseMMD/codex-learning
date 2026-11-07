# Moodiary V3 W2 — monthly immutable revision ledger

**Development foundation, not a finished APK feature.** This package adds a pure Dart month-level revision ledger and safety tests. One logical topic/month, one normal Diary in the final UI; each append has an immutable Block ID and revision history, with tombstones and a separately versioned optional monthly summary.

The current W1/Beta diaries are left **unchanged**. There is **no production migration** and the Web API remains **read-only** while the monthly storage adapter and safe WebDAV protocol are pending. The zip contents are two UTF-8 Dart files placed under `overlay/mobile/`; unpack them after applying W1 patches.

The ledger uses immutable revision graphs; merging concurrent revisions preserves multiple conflict heads instead of last-modified-wins overwrite. It rejects missing ancestry, colliding revision identities, duplicate block roots, invalid event dates or cross-month insertions. All tests are pure model tests, not real WebDAV multi-device validation.

CI must run `flutter test test/mod_monthly_ledger_test.dart --reporter expanded` from `upstream/mobile`, and still build existing `v3dev` flavor.

See `ledger-source.zip` for `mod_monthly_ledger.dart` and `mod_monthly_ledger_test.dart`.
