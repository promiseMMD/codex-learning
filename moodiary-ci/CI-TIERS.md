# Moodiary 3.0 — CI tiers, 2026-11-08

**Baseline:** W9.7.6 commit `49305a1ae05d808e569ac3c795a826fb84ebe419`, full W7 GitHub run `42450432090` **success** including arm64 APK.
Recent successful complete W7 runs were approximately **24–30 minutes**. Frequent full runs were blocking iterative feedback.

## CI routing

1. **Fast daily push/PR:** `.github/workflows/moodiary-v3-fast-ci.yml` runs on `moodiary-v3-*` feature branches; common pinned upstream/apply pipeline; Node syntax and JS safety; Dart editor & LAN smoke; on sensitive file changes also *restoration/migration* focused Flutter tests. No NDK, Rust or APK. Missing diff ancestry fails closed by enabling sensitive tests.
2. **Important integration:** every PR to `main` or `integration` runs fast then **complete regression** through reusable `moodiary-v3-full-ci.yml` (all previous browser, migrations, W1–W9.7.6 tests). Feature pushes may opt in once with commit message `[full-ci]`; after workflows exist on main, manual dispatch `tier=full`.
3. **APK delivery:** manual `tier=apk` or explicit `[apk-ci]` push runs fast then complete regression **on the same `github.sha`** and finally compiles a release arm64 APK. Artifact includes APK, SHA-256 and BUILD-PROVENANCE; 90-day retention. No APK before all checks pass.
4. **Formal release:** `moodiary-v3-release.yml` is **manual and only on main**; full CI + same-commit APK; protected environment `android-device-qa` should require human reviewers; fail closed unless provided device QA evidence URL, commit SHA and *exact APK SHA-256* match the artifact. It records QA attestation, **does not publish a release automatically**. Android real-device tests are human-attested, not CI-emulated.

**Important:** `workflow_dispatch` visibility for newly created workflows may require those workflow files to be merged into the repository's default `main` branch. While iterating on a feature branch, the opt-in `[full-ci]` / `[apk-ci]` commit markers allow the same callable workflows to be exercised without merging. Do not assume unmerged workflows are available in the GitHub Actions manual trigger menu.

## Maintainability
- Source assembly is moved to `moodiary-ci/prepare-workspace.sh` and reused verbatim by fast/full, eliminating duplicated patch order.
- Original `moodiary-v3-lan-w1.yml` remains unchanged for **transition parity**, but newly created feature branches are not added to its old hard-coded list. Remove its automatic push triggers only after parity and integration branch adoption.
- Full CI is a single reusable job, `build_apk=false` normally. Native NDK/Rust setup and APK upload require `build_apk=true`. Flutter action pub cache enabled.
- Sensitivity rules may over-trigger, never intentionally under-trigger on unknown Git state. The PR merge check runs full irrespective of file pattern to prevent data-risk escapes.
- Full QA protected environment must be configured with reviewers manually in GitHub repository settings. No automatic claims that this pipeline performed true device tests.
- If future app source changes require new historical overlays, update the shared prepare script and full test list together. Future branches should use fast workflow automatically, full on merge, APK on explicit delivery.
- CI timing targets are hypotheses, not measured. Check actual GitHub run times and step failures before claiming a speed-up.

## Next
Run first fast commit, address actual failures. Run a parity full acceptance on a commit containing `[full-ci]`; require green before switching main integration gate. Resume W9.7.7 real-device restoration fault work only after green CI tiering.
