# Moodiary progress audit — 2026-11-09

## 1. Existing app and signing

| Item | State | Notes |
|---|---|---|
| Old APK available | Confirmed by user | APK only; old private signing key unavailable |
| In-place update over old app | Not possible safely | Android signer mismatch; do not bypass |
| Parallel package identity | Implemented in W9.8.4.13 | New package cn.yooss.moodiary.v3safe |
| Old app data safety | Protected by design | No uninstall, overwrite or app-data clear |
| New persistent JKS | Pending user action | Generate once and retain offline backups |
| Actions signing secrets | Pending | Four secrets documented in W9.8.4.13 |
| Signed APK | Not built | Signing identity is not yet configured |

## 2. Upstream baseline

The previous build assembly pinned official release 2.9.2. W9.8.4.14 now pins
official develop commit 570ff99cd150fb2d45eb0949344f7bda22e32bde. The upstream
delta is two commits and is reviewed in UPSTREAM-BASELINE.md.

Fast CI on the final W9.8.4.14 commit and Full Acceptance are still required.
The earlier Fast CI success belongs to W9.8.4.13 and does not certify this new
baseline.

## 3. Data migration — major blocker

The normal upstream LocalArchive ZIP is not a complete backup of this
customized app. It covers ordinary Moodiary Diary/category/place data and
referenced media, but does not include the custom W9 monthly/day graph.

The W9 feature stores data in:
- mod_month_pages
- mod_month_blocks
- mod_month_revisions
- mod_month_heads
- mod_month_ops
- mod_day_pages

The current code already has a checksummed graph archive, staged ZIP packaging,
isolated restore, media verification and a read-only recovery inventory.
However, the graph export/ZIP/restore path is still explicitly offline/test-only.
It is not wired to the production backup/export screen or a live-database
migration import.

The current LAN month API exposes topics and month snapshots (latest heads),
plus revision writes. It is local-only and does not export the complete
revision/operation history. It is not a full-fidelity backup substitute.

Consequently, a normal ZIP import alone would leave custom long/month records
behind. Do not tell the user that migration is complete. Keep the old app
installed and untouched until a full migration package is implemented and
verified.

## 4. Read-only recovery inventory

W9.8.4.10/11 implements a non-mutating Android private recovery inventory in
Settings → Storage. The user's accepted scope is unchanged: list, statistics,
state and manual inspection only. No delete, purge, repair, journal recovery,
activation or live restore controls.

This inventory is separate from the new-app data migration flow. If a
migration/import screen is added, it must not expand or change the recovery
inventory's read-only contract.

## 5. Release/device acceptance still open

- Latest-upstream Fast CI.
- Full Acceptance CI on the exact release SHA.
- Production ordinary + custom graph export package.
- Safe new-app import into an empty target with transaction/readback checks.
- Full counts, FK/integrity checks, revision/head/operation verification.
- Media hash and actual-open checks.
- New persistent signing key and Actions secrets.
- APK manifest, ABI, v2 signer, certificate pin and SHA-256 verification.
- Xiaomi 14 Pro / HyperOS 3 parallel installation.
- On-device migration acceptance; keep old app and source backup untouched.

## 6. Next implementation sequence

1. Finish latest-upstream Fast CI and Full Acceptance.
2. Implement W9.8.4.15 production full-export integration, using the already
   verified graph/ZIP primitives rather than a second ad-hoc format.
3. Implement a separate safe migration import for the new package. Require an
   empty target, validate all archive receipts before writes, and verify full
   readback. Keep recovery inventory read-only.
4. Run failure-injection tests for truncated ZIPs, changed files, interrupted
   copy, DB transaction failure, media copy failure and restart recovery.
5. Only then request the new JKS/secrets, build the signed ARM64 APK, and run
   device acceptance.
