# W9.8.4.13 — Safe parallel installation and diary migration

## Why a parallel package is required

The W9.5.2 APK and the later W9.8.4.12 APK use the same Android package ID,
but their signing certificates differ. The old private signing key is not
available. An APK contains its signing certificate/public key, not the private
key, so the old signing identity cannot be recovered from the APK.

Android will reject an in-place update when the signing certificate differs.
The new build therefore uses a distinct application ID:

- Existing installation: "cn.yooss.moodiary.v3dev"
- Safe parallel installation: "cn.yooss.moodiary.v3safe"
- New launcher label: "Moodiary 安全版"

The old installation is never uninstalled, overwritten, cleared, or modified.
The two installations have separate Android application sandboxes and databases.

## Supported migration path

The pinned Moodiary source already includes a complete local backup flow:

- Backup export calls IBackupArchive.export().
- Backup restore picks a ZIP and calls IBackupArchive.import().
- The archive includes diaries, categories, places, tombstones, and referenced media.
- Restore uses RestorePolicy, which does not apply backup tombstones as deletion
  commands to the new installation.

The archive does not migrate application preferences, app-lock credentials,
WebDAV credentials, or other device-specific settings. Configure those again in
the new installation. Nutstore/WebDAV compatibility is not part of this signing
and parallel-install stage.

### User migration sequence

1. Keep the old Moodiary app installed and working.
2. In the old app, open its Export page and use **Backup → Export backup**.
3. Save/share the generated ZIP to a private location such as Downloads or a
   computer. The ZIP contains personal diary data and media and is not encrypted
   by the built-in local-backup implementation; do not put it in a public folder.
4. Confirm the ZIP exists and has a plausible non-zero size. Keep a second copy
   until migration has been verified.
5. Install **Moodiary 安全版**. Its package ID is different, so Android installs
   it alongside the old app instead of replacing it.
6. Open the new app and, before creating new diaries, use **Export → Backup →
   Restore from backup** to select the ZIP.
7. Wait for the import result. Investigate any failed or skipped items.
8. Verify diary counts, representative older/newer entries, categories, places,
   images, audio, video, and attachments. Check media by opening actual entries,
   not only by checking the reported count.
9. Keep the old app and the original ZIP unchanged until the new installation
   has been used and checked over several days.

The migration is a backup/restore operation, not a direct copy of private Android
files. The old database is not opened by the new app and is not modified by import.

## Signing key setup for repeatable future updates

A new, stable signing key must be created once for the new package and retained
for every future release. Never regenerate it after installing the first
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

Also keep two offline copies of the generated JKS file. Do not commit the JKS,
Base64 keystore, or passwords to Git. The APK workflow fails closed if the
secrets are missing, the alias is wrong, or the certificate fingerprint does
not match.

## Release gates

A deliverable APK must pass all of the following:

- Package ID is exactly cn.yooss.moodiary.v3safe.
- Version is 2.9.3+125.
- ABI is ARM64 only; min SDK 28 and target SDK 36.
- APK v2 signature verifies.
- Signer certificate SHA-256 equals the pinned Actions secret.
- The old package ID remains different, so parallel installation is guaranteed.
- APK SHA-256 and build provenance are retained beside the APK.

No APK should be presented as an installable release until the persistent signing
key has been configured and all release gates pass.
