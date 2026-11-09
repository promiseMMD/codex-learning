# W9.8.4.12 Technical Design — APK build and device-test gate

## 1. Purpose
Turn the already accepted W9.8.4.11 source baseline into a traceable Android ARM64 test artifact without confusing CI success with real-device acceptance or production release.

## 2. Immutable source
- Parent: `facad28a0fd09cd55efde9a0e797e8af8c2bf89e`.
- Pinned upstream: `ZhuJHua/moodiary@2c552ddd7939a054122380397fb914cf000824b0`.
- All overlays are assembled by the existing shared `moodiary-ci/prepare-workspace.sh`.
- Fast and Full CI must both run against the same final `github.sha`; APK build is a downstream job of the Full Acceptance workflow.

## 3. CI route
1. Commit includes `[apk-ci]`.
2. Fast CI performs its normal contract, browser, editor, mobile, storage, recovery and sensitive-change checks.
3. Only after Fast succeeds, `apk-after-fast` calls the reusable Full CI with `build_apk=true`.
4. Full Acceptance runs complete browser, database migration, editor, media, storage, archive, WebDAV and V1/V2 SIGKILL suites.
5. Only after the complete suite passes does the workflow install NDK/Rust build prerequisites and compile the ARM64 release-mode development flavor.
6. The exact same commit SHA and artifact are retained together.

## 4. APK validation
`moodiary-v3-w9-8-4-12/verify_apk.py` uses only Python standard library to inspect:
- ZIP CRC integrity and binary Android manifest.
- Exact package `cn.yooss.moodiary.v3dev`, versionName `2.9.2`, versionCode `124`.
- minSdk 28 and targetSdk 36.
- ARM64-only native library layout.
- LAN API v3 JavaScript and native editor snapshot assets.
- APK signing block and v2 signer certificate SHA-256.

The workflow additionally runs Android `apksigner verify` and `aapt dump badging`, and stores their complete reports. It calculates the final APK SHA-256 and emits `BUILD-PROVENANCE.txt`.

## 5. Signature compatibility
The previous W9.5.2 development artifact used signer certificate SHA-256 `19a9a5816297abfac1daaba0fbeeeedfd5bc8a67aa42e479aa60a3534c880b3a`.
The new certificate must be compared before installation. A different signer does not justify uninstalling the previous app or clearing its data. Such an APK remains a separate artifact until a stable signing-key plan is established.

A release-mode build can still be signed with Android Debug if the Gradle project has no persistent release keystore and local signing properties. The artifact must therefore be described as a development test APK, not a production-signed APK.

## 6. Device QA boundary
Linux CI does not prove Android private-storage ownership, foreground service behavior under lock, OEM process management, runtime permissions, upgrade compatibility or HyperOS 3 behavior.
Those are verified on the actual Xiaomi 14 Pro only after the artifact SHA and signer are known. No uninstall, app-data clear, restore or destructive sync operation is part of this acceptance.

## 7. Safety
W9.8.4.11's read-only recovery inventory contract remains unchanged. This stage must not add delete, purge, repair, journal recovery, automatic recovery, or live database replacement. Nutstore-specific compatibility expansion remains paused.
