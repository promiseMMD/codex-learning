# W9.8.4.12 — ARM64 APK build and device-test gate

## Baseline and branch
- Previous accepted stage: W9.8.4.11, commit `facad28a0fd09cd55efde9a0e797e8af8c2bf89e`.
- Branch: `moodiary-v3-w9-8-4-12-apk-qa-20261109`.
- This stage does not rewrite or replace W9.8.4.11.
- Exact source commit must pass Fast CI and Full Acceptance before APK build.

## Scope
Build a release-mode, development-channel ARM64 APK for physical-device QA:
- Application ID: `cn.yooss.moodiary.v3dev`.
- Version: `2.9.2+124` (`versionName=2.9.2`, `versionCode=124`).
- Flavor: `v3dev`.
- ABI: `arm64-v8a` only.
- Build command: `flutter build apk --flavor v3dev --release --target-platform android-arm64`.
- Trigger: a commit message containing `[apk-ci]`; Fast CI must pass, then the same SHA runs Full Acceptance and APK build.

This is a development/device-test artifact, not a production release and not permission to merge to `main`.

## Artifact acceptance
The build must retain:
- APK binary.
- APK SHA-256 checksum.
- APK structural verification JSON.
- Android apksigner report and certificate fingerprint.
- AAPT manifest/badging report.
- Build provenance containing source commit, pinned upstream commit, workflow run, package, version, ABI, and signer comparison.

Fail the APK job if any of the following is wrong:
- ZIP CRC or APK signing block.
- APK v2 cryptographic signature verification.
- Package ID or version name/code.
- minSdk 28 / targetSdk 36.
- Any non-ARM64 native ABI, or missing ARM64 native libraries.
- LAN API v3 JavaScript asset or native editor snapshot assets.

## Signing and user-data safety
The previous W9.5.2 development APK was verified with signer certificate SHA-256:
`19a9a5816297abfac1daaba0fbeeeedfd5bc8a67aa42e479aa60a3534c880b3a`.

Compare the new signer with that fingerprint:
- Same fingerprint: signature compatibility with that previous development APK is preserved.
- Different fingerprint: do not update-install over the existing app. Do not uninstall it, clear app data, or attempt to bypass Android signature checks. Keep the APK as a separately reviewed artifact and resolve stable signing before upgrade testing.

Never claim an APK is production-signed merely because it is a release-mode build. The Gradle project can fall back to the runner's Android Debug keystore when a persistent release keystore is not configured.

## Physical-device acceptance — not yet performed by CI
On the Xiaomi 14 Pro / HyperOS 3, use the exact artifact SHA and only proceed with installation when the signer check is compatible with the installed package:
1. Install/upgrade without uninstalling or clearing app data.
2. Launch and inspect Settings → Storage → recovery inventory; confirm read-only behavior.
3. Open ordinary diary, long-term records, daily/monthly views and rich-text editor.
4. Inspect existing images and image attachment display.
5. Exercise LAN pairing and PC read/write only on a trusted local network; verify lock-screen foreground-service behavior.
6. Confirm existing sync configuration and local data remain present. Do not perform destructive sync/restore experiments.
7. Record device model, HyperOS/Android build, APK SHA-256, signer fingerprint, results and screenshots/logs.

Nutstore-specific compatibility expansion remains paused; do not introduce new Nutstore behavior in this stage. Existing automated WebDAV/Nutstore security regressions remain required.

## Explicitly excluded
- No delete, purge, repair, journal recovery, or formal restore UI.
- No automatic recovery.
- No overwrite or cleanup of backup copies.
- No database reset or app-data clearing.
- No production release, Play Store publication, or main merge.
- No claim of HyperOS compatibility until actual device evidence exists.

## Exit criteria
W9.8.4.12 build gate passes only when Fast CI, Full Acceptance, APK structural checks, v2 signature verification and provenance artifact all succeed on the exact same commit SHA. Physical device QA remains a separate gate.
