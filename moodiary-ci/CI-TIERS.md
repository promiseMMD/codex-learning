# Moodiary 3.0 — CI tiers, 2026-11-08

> **当前 v3safe 状态（2026-11-10）**：永久 `applicationId` 已按 V1.0 D02 固定为 `cn.yooss.moodiary.v3safe`，当前候选目标版本为 `2.9.2+126`。开发分支 `moodiary-v3-w9-8-4-31-permanent-application-id-20261110` 的 Fast CI `42811784803` 已通过；该运行的 `full-after-fast` 与 `apk-after-fast` 均为 skipped，且没有 APK Artifact，因此不能标记 Full CI、签名 APK 或设备验收完成。`[full-ci]` 用于同一分支完整回归（不出 APK）；`[apk-ci]` 才会在完整回归后尝试构建签名候选包，并要求四项 `MOODIARY_SAFE_*` Secrets。下文 W9.8.4.12 的 v3dev 构建是历史阶段记录，不是当前包名或版本目标。

**Baseline:** W9.7.6 commit `49305a1ae05d808e569ac3c795a826fb84ebe419`, full W7 GitHub run `42450432090` **success** including arm64 APK.
Recent successful complete W7 runs were approximately **24–30 minutes**. Frequent full runs were blocking iterative feedback. W9.8.4.11 adds read-only recovery inventory root and UI tests to both Fast and Full tiers.

## CI routing

1. **Fast daily push/PR:** `.github/workflows/moodiary-v3-fast-ci.yml` runs on `moodiary-v3-*` feature branches; common pinned upstream/apply pipeline; Node syntax and JS safety; Dart editor & LAN smoke; on sensitive file changes also *restoration/migration* focused Flutter tests. No NDK, Rust or APK. Missing diff ancestry fails closed by enabling sensitive tests.
2. **Important integration:** every PR to `main` or `integration` runs fast then **complete regression** through reusable `moodiary-v3-full-ci.yml` (all previous browser, migrations, W1–W9.7.6 tests). Feature pushes may opt in once with commit message `[full-ci]`; after workflows exist on main, manual dispatch `tier=full`.
3. **APK delivery:** manual `tier=apk` or explicit `[apk-ci]` push runs fast then complete regression **on the same `github.sha`** and finally compiles a release arm64 APK. Artifact includes APK, SHA-256 and BUILD-PROVENANCE; 90-day retention. No APK before all checks pass.
4. **Manual Android QA evidence gate:** `moodiary-v3-release.yml` uses `workflow_dispatch` and the protected environment `android-device-qa`; its current job allows `main` and the approved `moodiary-v3-w9-8-4-*` candidate branch family. GitHub may require the workflow file to exist on the default branch before the manual trigger appears in the UI. The gate fails closed unless the supplied device QA evidence URL, commit SHA and *exact APK SHA-256* match the downloaded candidate artifact. It records QA attestation, **does not publish a release automatically**. Android real-device tests are human-attested, not CI-emulated; formal release still requires all V1.0 gates.

**Important:** `workflow_dispatch` visibility for newly created workflows may require those workflow files to be merged into the repository's default `main` branch. While iterating on a feature branch, the opt-in `[full-ci]` / `[apk-ci]` commit markers allow the same callable workflows to be exercised without merging. Do not assume unmerged workflows are available in the GitHub Actions manual trigger menu.

## Maintainability
- Source assembly is moved to `moodiary-ci/prepare-workspace.sh` and reused verbatim by fast/full, eliminating duplicated patch order.
- Push cancellation is scoped to the `fast` job only. A newer push may replace a still-running fast check, but cannot cancel a Full Acceptance run that has already started; the reusable full workflow retains `cancel-in-progress: false`.
- Original `moodiary-v3-lan-w1.yml` remains unchanged for **transition parity**, but newly created feature branches are not added to its old hard-coded list. Remove its automatic push triggers only after parity and integration branch adoption.
- Full CI is a single reusable job, `build_apk=false` normally. Native NDK/Rust setup and APK upload require `build_apk=true`. Flutter action pub cache enabled.
- Sensitivity rules may over-trigger, never intentionally under-trigger on unknown Git state. The PR merge check runs full irrespective of file pattern to prevent data-risk escapes.
- Full QA protected environment must be configured with reviewers manually in GitHub repository settings. No automatic claims that this pipeline performed true device tests.
- If future app source changes require new historical overlays, update the shared prepare script and full test list together. Future branches should use fast workflow automatically, full on merge, APK on explicit delivery.
- CI timing targets are hypotheses, not measured. Check actual GitHub run times and step failures before claiming a speed-up.

## Historical stage: W9.8.4.12 — v3dev APK device-test build (superseded)

This section documents the earlier `cn.yooss.moodiary.v3dev` test APK only. It is not the current v3safe package identity or current candidate version; use the current v3safe release workflow and V1.0 D02 instead.
- Baseline: W9.8.4.11 `facad28a0fd09cd55efde9a0e797e8af8c2bf89e`.
- Build only from the exact commit that passed Fast CI and Full Acceptance, using `[apk-ci]`.
- Produce the `v3dev` ARM64 release-mode test APK (`cn.yooss.moodiary.v3dev`, version `2.9.2+124`). This is a device-test artifact, not a production release.
- Verify ZIP CRC, APK signing block, v2 cryptographic signature, package/version, min/target SDK, ARM64-only native libraries, LAN JavaScript and native editor assets; retain SHA-256, signature report, manifest and source provenance.
- Compare the signer certificate with the previous W9.5.2 development APK (`19a9a5816297abfac1daaba0fbeeeedfd5bc8a67aa42e479aa60a3534c880b3a`). A mismatch is a hard warning: do not update-install over the existing app, uninstall it, or clear data.
- Physical Xiaomi 14 Pro / HyperOS 3 acceptance remains a separate user-device gate. Do not claim CI proves device behavior.
- Formal release remains blocked until stable signing, exact-artifact device QA evidence and the main-only release gate are satisfied.

## Next (current v3safe branch)
1. Run `[full-ci]` on the exact current candidate commit and inspect every full-regression job; Fast CI success alone is insufficient.
2. Generate one persistent v3safe JKS locally with the repository script, retain two offline copies, and configure the four `MOODIARY_SAFE_*` GitHub Actions Secrets. Never send the JKS, Base64 keystore or passwords in chat or commit them to Git.
3. Only after Full CI passes and signing secrets are configured, trigger `[apk-ci]` on an immutable commit. Verify the artifact package, version, signer fingerprint, source commit and SHA-256.
4. Perform controlled sample tests first, then validate an actual official-original backup under V1.0 C06 and complete real-device QA. Keep the original app and its data untouched throughout.

## Live acceptance
- Fast CI run `42452907014`: **success** in 4.1 min (2026-11-08 05:59:54–06:04:02 UTC). Historic full W7 run `42450432090`: ~29 min; different test suites.
- Fast now verifies a regression contract for mandatory database/restore tests; direct pushes to main/integration require complete regression too. One-time `[full-ci]` parity run required before retirement of old W7 workflow.
