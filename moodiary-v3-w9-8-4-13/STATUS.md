# W9.8.4.13 — Parallel-safe installation

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
