# Moodiary 3.0 W9.8.2 — daily home preview, non-destructive

Parent: W9.8.1 commit `0cfcda15da2092ecd655540f4b406f9ec4b2a4c0` (Fast + Full CI success).

## Implemented
- Home `DiaryHomePage` displays a compact horizontal preview of newest W9 per-topic daily entries above the ordinary Diary list, for the All filter only. These are read-only *virtual cards*, NOT newly created native Diary database rows.
- Uses verified W9 readMonth and buildModDayPreviews, last 3 event-ordered entries, summary and tombstone excluded, stale multi-head conflict rejects the whole read (no silent LWW).
- The only new database write is a reversible `mod_day_pages.visible_local` setting; no changes to `diaries.show`, Diary content, network or ZIP.
- Open card always routes to native `ModMonthPage(dayKey:)` and its existing structured CAS composer, never ordinary Diary editor. No bulk selection/deletion path for virtual cards.
- Home updates on native/PC commit invalidation, foreground resume and normal Diary changes. Error hides stale cards and blocks navigation.
- Max 20 visible cards in the horizontal strip with explicit truncated-count note; reads reject more than 512 topic-month partitions instead of silently presenting a supposedly exhaustive list.
- Dedicated SQLite and Flutter widget tests plus Fast/Full CI gate; developer build number +112.

## Deferred by design
- True native DailyDiary materialization to ordinary `diaries` table, integrated default date sorting in both native Feed/Timeline, and conflict-safe bidirectional projection. These require a full backup/restore format carrying day mapping, immutable revisions, tombstones and media; not claimed here.
- I18n translations of the new home shortcut labels, Android device QA, release APK and stable signing.
- Nutstore special compatibility explicitly paused. No changes to that provider.

## Acceptance
- Fast and Full CI must pass on the final commit. A passing CI is still not an Android device acceptance.