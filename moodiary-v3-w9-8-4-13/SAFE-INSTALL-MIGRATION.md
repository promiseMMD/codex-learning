# W9.8.4.13 — Safe parallel installation and migration status

## 1. Signing constraint and install strategy

The existing W9.5.2 / W9.8.4.12 APKs use the same Android package ID,
but their signing certificates differ. The old private signing key is not
available. An APK contains its signing certificate/public key, not the private
key, so the old signing identity cannot be recovered from the APK.

Android rejects an in-place update when the signer differs. Do not attempt to
bypass Android's signature check.

The safe build therefore uses a distinct application ID:

- Existing installation: cn.yooss.moodiary.v3dev
- Safe parallel installation: cn.yooss.moodiary.v3safe
- New launcher label: Moodiary 安全版

The old installation is never uninstalled, overwritten, cleared, or modified.
The two installations have separate Android application sandboxes and databases.

## 2. Important correction: full data migration is NOT ready

The previous draft of this document overstated what the built-in backup ZIP
covers. That claim is corrected here.

The upstream LocalArchive ZIP flow covers ordinary native Moodiary data
(diary/category/place records and referenced media). It does NOT currently
include the custom W9 monthly-record graph.

The custom monthly feature uses these SQLite tables:

- mod_month_pages
- mod_month_blocks
- mod_month_revisions
- mod_month_heads
- mod_month_ops
- mod_day_pages

The custom archive work already contains useful building blocks:

- ModMonthGraphArchiveV1/V2 can serialize and validate the custom graph,
  including revision history, heads, operation IDs and day mappings.
- ModMonthStreamStageV2 can stage and hash files.
- ModMonthZipBundleV2 can package and verify an offline ZIP.
- ModMonthIsolatedRestoreV2 can restore native data, graph and media into a
  brand-new isolated directory/database and verify readback.
- ModMonthRestoreInventoryV2 and the W9.8.4.11 Settings panel can inspect
  private recovery copies read-only.

However, these components are deliberately not yet connected to the production
backup/export UI or a production live-database import. Their source comments
explicitly state that production ZIP export/restore and WebDAV integration are
not enabled. The recovery inventory also intentionally has no delete, repair,
activation or live-restore action.

Therefore, exporting and importing only the ordinary upstream ZIP would not
constitute a complete migration of the current customized Moodiary app.
Do not mark migration complete or ask the user to rely on that ZIP alone.

## 3. Required migration implementation before release

A subsequent implementation stage must:

1. Extend one user-facing backup package to include both ordinary Moodiary
   records/media and the complete W9 monthly/day graph.
2. Preserve all five monthly tables, all revision history, tombstones, heads,
   operation IDs, day mappings, native Diary bindings where supported, and
   referenced media.
3. Verify the archive manifest, per-file sizes and SHA-256 hashes before import.
4. Import into the new app only through a separately designed migration flow;
   never overwrite the old app or its private database.
5. Restrict first migration to a fresh/empty target database unless a tested,
   explicit merge policy is implemented.
6. Verify database integrity, foreign keys, row counts, graph readback and
   actual media opening after import.
7. Keep the original ZIP and old app unchanged until the user has checked the
   new app over several days.

The read-only recovery inventory remains read-only. A migration/import flow,
if later approved and implemented, must be a separate screen and code path.

## 4. New persistent signing identity

A new signing key must be created once for the new package and retained for
every future v3safe release. Never regenerate it after installing the first
Moodiary 安全版 APK.

Run generate-safe-signing-key.ps1 on Windows. It creates a JKS file outside
the repository, copies its Base64 encoding to the clipboard, and prints the
certificate SHA-256 fingerprint. Add these repository Actions secrets:

- MOODIARY_SAFE_KEYSTORE_BASE64: the clipboard Base64 value
- MOODIARY_SAFE_STORE_PASSWORD: the keystore password
- MOODIARY_SAFE_KEY_PASSWORD: the key password (the generator uses the same
  password for both)
- MOODIARY_SAFE_CERT_SHA256: the printed SHA-256 fingerprint, hex without
  colons

Keep two offline copies of the generated JKS file. Never commit the JKS,
Base64 keystore, or passwords to Git. CI must fail closed if the secrets are
missing, the alias is wrong, or the certificate fingerprint does not match.

## 5. Release gates

Do not publish an installable APK until all of the following pass:

- Latest official Moodiary develop baseline is pinned and recorded.
- Full CI passes on the exact release commit.
- Package ID is exactly cn.yooss.moodiary.v3safe.
- Version is 2.9.3+125.
- ABI is ARM64 only; min SDK 28 and target SDK 36.
- APK v2 signature verifies.
- Signer certificate SHA-256 equals the persistent Actions secret.
- Complete ordinary + W9 custom-data migration has production export/import
  coverage and passing end-to-end tests.
- APK SHA-256 and build provenance are retained beside the APK.
- Xiaomi 14 Pro / HyperOS 3 installation and migration acceptance passes.

Until then, keep the old app installed and its data untouched.