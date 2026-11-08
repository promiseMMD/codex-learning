# Moodiary W9.6 | fail-closed legacy archive safety gate

Base: W9.5.2 verified implementation `b0e80ef56f912912a135df997300dc5eefa2f92b`; branch `moodiary-v3-w9-5-2-day-timeline-20261108`.
New branch: `moodiary-v3-w9-6-archive-gate-20261108`, version `2.9.2+102` (development).

Legacy cloud / ZIP archives serialize Diary/Category/Place/legacy tombstones but not the W9 Topic/Month/Block/Revision/Head/Operation graph. This release adds a preflight that refuses upload/download/full sync, ZIP export/delta/restore, local manifest and direct archive apply whenever the five structured tables are incomplete, unreadable or contain any rows. **This deliberately blocks legacy cloud and ZIP on devices containing structured W9 data, until a versioned full-format archive exists.**

- Real production sync uses RepoSyncDiaryStore and performs the v4 SQLite check before *any* remote operations and before lastSyncTime can be marked.
- Local export and import deny before generating/recovering files. Existing ordinary diaries and remote content remain untouched.
- All-empty v4 tables permit the original ordinary diary backup/sync path.
- Fake-store engine tests remain isolated and run their existing regression suite.
- Data tests verify empty v4, nonempty mapping, missing schema and nonmutating denial.
- Integration tests verify all three network directions have zero remote calls, ZIP refusal and fake-store compatibility.
- Does not create a DailyDiary, migrate Alpha/Beta, change sqlite schema, add a hidden tag, or mark W9 blocks cloud-synced.

**Status:** Code checkpoint. The GitHub Actions run and its APK artifact must be verified separately; do not call this release accepted before CI passes.

**Next:** versioned full archive with content hash, DAG head preservation, ops, tombstones, media and isolated restore. Then stable topic+day -> one native Diary, display preference, dedicated editing and cross-device merge.
