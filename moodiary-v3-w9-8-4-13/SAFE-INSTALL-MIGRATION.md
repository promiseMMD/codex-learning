# W9.8.4.13 — Safe installation and migration status (V1.0-aligned)

> **Current source of truth:** [Moodiary Mod Project Spec V1.0](../docs/MOODIARY_MOD_PROJECT_SPEC_V1.0.md).
> This note is an engineering handoff, not an authorization to change project scope.
> The user's existing notes are in the official ZhuJHua/moodiary app. The modified app has no user notes.
> Initial migration means **official original app → final modified app** only. Do not require migration of nonexistent old modified-app W9 history.
>
> **Permanent package identity (D02, user-approved 2026-11-10):** `cn.yooss.moodiary.v3safe` is the permanent applicationId of the modified app. This approval is final for the package identity. A build may still be labelled a signed QA candidate while migration/device/release gates remain incomplete; QA status describes the artifact's verification state, not a temporary or unapproved package name.

## 1. Installation and signing boundaries

- Official original package: `cn.yooss.moodiary`.
- Historical modified development package: `cn.yooss.moodiary.v3dev`.
- **Permanent modified applicationId: `cn.yooss.moodiary.v3safe` (D02 user-approved 2026-11-10).**
- The `v3safe` Gradle flavor is the permanent app identity. `signed-QA-candidate-not-formal-release` is only an artifact readiness label; it does not make the package name temporary.
- The original app and its data must remain installed and untouched until the first-import acceptance passes.
- Every future modified-app build must retain the exact same applicationId and signing identity so normal in-place upgrades remain possible.
- Never bypass Android signature checks or generate a replacement key after the first formal release.

The old development APK's private signing key is unavailable. A public certificate extracted from an APK cannot recreate its private key. A different signer cannot perform an in-place Android update. The permanent `v3safe` package remains separate from both the official original and historical `v3dev` installation, allowing parallel installation without overwriting either.

## 2. Official original backup format — verified source behavior

The pinned upstream source is `ZhuJHua/moodiary@2c552ddd7939a054122380397fb914cf000824b0`.

At that commit, `LocalArchive.export()` reads native Diary, Category, Place and Tombstone records and packages referenced media from the app support directory. The archive import path extracts a ZIP and requires the native sync manifest. The importer explicitly detects and rejects legacy Isar `.isar` backups instead of silently treating them as the current ZIP format.

Consequences:

1. Do not assume every installed official version exports the same ZIP format.
2. Before migration, record the user's installed official app version and export a backup using that app's own backup UI.
3. Inspect a copy of the ZIP read-only. Confirm manifest presence, record objects, media entries and archive integrity before attempting import.
4. If the official app produces a legacy Isar backup or an unsupported archive, stop and design a narrowly scoped compatibility path. Do not alter the official app or its data.
5. Keep the original backup file unchanged. Import only into an isolated, empty modified-app target.

The native archive source includes ordinary Diary/Category/Place/Tombstone records and referenced media. The actual backup from the user's installed app remains the authority for the migration test; source inspection alone is not proof that the user's archive is compatible.

## 3. First migration acceptance — C01/C05/C06/C07

The required one-time path is official original app → final modified app. Acceptance must verify:

- Total diary count against the official app/source backup.
- Plain text and rich-text content.
- Creation/modification timestamps and diary date mapping.
- Categories, tags, places and other metadata actually present in the source.
- Image/audio/video/other attachment presence, openability and content; compare SHA-256 where applicable.
- No unexplained skipped, failed or partially imported records.
- Target database integrity and media references after import.

A partial import must be reported as partial, never as complete success. The original app, its database and the original ZIP remain untouched until the user has reviewed the migrated result. Do not uninstall the original app or clear its data before acceptance.

## 4. W9 custom monthly/day feature — preserve, but do not expand migration scope

The modified app contains custom monthly/day structures and supporting archive/recovery code. Preserve these existing features and their tests; do not delete or casually refactor them.

The graph includes the `mod_month_pages`, `mod_month_blocks`, `mod_month_revisions`, `mod_month_heads`, `mod_month_ops` and `mod_day_pages` tables.

However, the official original app does not contain the modified app's W9 custom monthly/day graph, and the modified app has no user notes to migrate. Therefore:

- W9 graph/revision/history migration is not a prerequisite for this user's first migration.
- Do not connect experimental W9 graph archives to the ordinary official ZIP import merely to satisfy an obsolete handoff checklist.
- Do not require nonexistent old modified-app history as a release blocker.
- Continue testing existing W9 features for their own correctness and data safety, without expanding the official-to-modified first-import scope.

## 5. Persistent signing identity

Create one long-term signing identity for the final modified app and retain two offline copies of the JKS. Never commit the JKS, Base64 keystore or passwords to Git. Configure these repository Actions secrets only through GitHub's secret settings:

- `MOODIARY_SAFE_KEYSTORE_BASE64`
- `MOODIARY_SAFE_STORE_PASSWORD`
- `MOODIARY_SAFE_KEY_PASSWORD`
- `MOODIARY_SAFE_CERT_SHA256`

CI must fail closed if any secret is absent, the alias is wrong, or the certificate fingerprint does not match. Presence-only preflight is not a substitute for the later JKS and APK certificate verification. Never use a debug or ephemeral signer as a fallback.

The persistent signer configured for `cn.yooss.moodiary.v3safe` must be used consistently for QA builds and all future formal releases. Before first formal release, verify its certificate fingerprint against the APK; after the first formal release, never regenerate or replace the signing key. The package ID is already approved; signing-key configuration and validation remain pending.

## 6. Formal release gates

Do not publish or describe an APK as the formal long-term app until all applicable V1.0 gates pass:

- Official upstream Release/Tag and exact commit are pinned and recorded.
- The permanent applicationId is fixed as `cn.yooss.moodiary.v3safe` under D02. Gradle flavor, APK Manifest, structural verifier, CI provenance and delivered APK must all match this exact value; do not rename it in future releases.
- Display version follows the adapted official Release; each formal APK's integer `versionCode` exceeds the previous formal release.
- One persistent signing key is used; APK package, signature and SHA-256 are verified.
- Full CI passes on the exact source commit.
- Official original ZIP → final modified app migration passes C06 on a real backup from the user's installed official version.
- Coverage includes install coexistence, approved modified features, data integrity, backup/restore, database upgrade and required real-device checks.
- Xiaomi 14 Pro / HyperOS 3 device acceptance is recorded where applicable.

A signed QA candidate is not a formal release. Its package identity is nevertheless the permanent `cn.yooss.moodiary.v3safe`. Fast CI success is not device acceptance. Until the original-to-modified migration and device acceptance pass, keep the original app and its data untouched.
