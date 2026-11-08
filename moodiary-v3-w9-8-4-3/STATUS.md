# Moodiary W9.8.4.3 — V2 generation slot and real SIGKILL

Base W9.8.4.2 commit c6a948edc20dc28c3186b52f14e0af4030b2d43c (Fast and Full green).

## Implementation
- ModMonthRecoverySlotV2: dedicated V2 slot identity, v2 ready-state and v2 generation proof, rejecting V1 roots and V1 cold restore sources.
- Private incoming generation, independent SHA-256 SQLite/media inventory, V2 Graph2 checksum, directory rename and atomic active.json pointer.
- Seven crash checkpoints: journal_written, files_copied, generation_verified, directory_moved, generation_installed, pointer_written and journal_committed.
- Before pointer commit: roll back. After pointer commit: recover committed generation. If new committed generation is corrupt and journal survives, reverify old generation and revert pointer.
- currentDirectory and recover revalidate the SQLite database, V2 month/day graph integrity, native file inventory and media SHA-256.
- Real Linux SIGKILL of Flutter-engine child at two fast / seven full checkpoints: verify V2 daily visibility, native Diary identity, both source media versions and absence of leaked incoming directory.
- CI retains V1 tests and V1 SIGKILL suite independently; developer version 2.9.2+116.

## Explicit safety boundary
- A developer-only isolated two-generation slot, not production app SQLite/media migration.
- No live restore, WebDAV/Nutstore changes, main merge, APK, or real Android device QA.
- W9.8.5 native DailyDiary projection can be considered only with graph/media full recovery and protected edit paths preserved.

Accept only when Fast and Full CI pass on exact HEAD.