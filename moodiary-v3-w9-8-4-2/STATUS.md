# Moodiary W9.8.4.2 — V2 ZIP and cold isolated recovery

Base W9.8.4.1 commit a5e99c580dac8e6a8be18fc7296b24d59c170e14 (Fast+Full green).

## Implemented
- V2 ZIP creation from already verified native/GraphV2/media stage. Atomic output rename only after independent extract/readback and hash manifest validation.
- V2 ZIP preflight validates ZIP central directory, entry names and counts, size ceilings, encryption/unsupported compression, symlink/special-file flags, archive bounds, and required V2 manifest/graph. V1 archive graph/manifest files cannot be substituted.
- Fresh isolated V2 cold recovery: reconstruct original native Diary/category/place/tags/media links/tombstones plus all W9 month graph revisions/heads/ops AND day mappings/visibility from V2 graph; independent file SQLite verification, foreign keys and integrity check, every copied media SHA-256 versus V2 archive receipts.
- Injected restore failure cleans private staging and refuses to publish partially restored directories. A prior destination is not overwritten. V2 readback verifies exact structured graph and native entities.
- V2 restore-state uses distinct version=2 format so older W9.7.6 V1 recovery slot cannot misidentify a V2 generation.
- Fast and Full CI include real Python-generated ZIP test cases, missing day graph, tampered ZIP, failures across restore checkpoints, and preservation of original media and Diaries. Dev version 2.9.2+115.

## Not activated (critical)
- V2 ZIP creation, isolation and cold restore are developer/testing capability only. NO production Android backup or live restore, no WebDAV/Nutstore changes, and no switch to new native DailyDiary projection.
- W9.8.4.3 needs version-2 generation proof and independently verified crash-safe two-generation promotion, actual SIGKILL checkpoint matrix and media-aware before/after-commit rollback.
- Physical Android/HyperOS device QA, signed APK and production backup UX remain future tasks.

## Acceptance
- Only Fast CI and Full CI success on exact HEAD establishes baseline. Tests do not mean the app is ready for user-data restore.