# W9.8.4.13 — Parallel-safe installation

> **历史阶段快照（2026-11-10 规范对齐）**：本文记录 v3safe flavor 初次引入时的实现状态，不是当前发布状态的唯一依据。永久包名已由 V1.0 D02 固定为 `cn.yooss.moodiary.v3safe`；当前候选构建目标以 `moodiary-v3-w9-8-4-12/verify_apk.py` 和 Full CI 为准（`2.9.2+126`）。首次迁移范围以 V1.0 C01/C04–C07 和本目录 `SAFE-INSTALL-MIGRATION.md` 为准：官方原版 → v3safe；不得把“官方原版必须含有 W9 自定义历史”作为前置条件。W9 图谱的完整性保护和回归测试仍须保留。

## Implemented

- Adds a separate v3safe Android flavor and package ID
  cn.yooss.moodiary.v3safe.
- Uses the launcher label Moodiary 安全版.
- Bumps the safe build to 2.9.3+125.
- Keeps the existing cn.yooss.moodiary.v3dev installation unchanged.
- Adds a stable new signing-key generator and fail-closed CI signer checks.
- Adds patch unit tests and migration-contract checks.

## Verified so far

- W9.8.4.13 patch unit tests passed in the first Fast CI run.
- The complete preparation script and safe flavor injection passed.
- A later Fast CI run on the latest-upstream branch is in progress / must be
  checked before this stage is accepted.

## Not complete — release blockers

1. User has not yet generated the new persistent JKS key or added the four
   repository Actions secrets.
2. Full CI has not yet passed on the latest-upstream release candidate.
3. The ordinary upstream LocalArchive ZIP does not include the custom W9
   monthly/day graph.
4. The custom W9 graph archive, streaming ZIP and isolated restore are currently
   offline/test-only; no production backup UI or live-database migration path
   is wired.
5. Full ordinary + custom data migration has not been verified end to end.
6. A signed ARM64 APK has not been built or verified for the new key.
7. Xiaomi 14 Pro / HyperOS 3 install and data validation have not been run.

## Safety invariants

- Never uninstall, overwrite, clear storage, or reset the old app.
- Never change the old package ID to force an update.
- Never store a keystore or password in Git.
- Do not distribute the APK until the custom-data migration blocker and all
  signing/build/device gates are resolved.
- The Settings recovery inventory remains read-only; no delete, repair,
  activation or live-restore controls are to be added there.
