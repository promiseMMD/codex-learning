# W9.8.4.13 — Parallel-safe install and backup migration

## Scope

Replace the impossible old-key recovery path with a new package identity that
can coexist with the existing installation, while retaining the old app's
database untouched.

## Implemented in this patch

- Adds v3safe Android flavor with package ID
  cn.yooss.moodiary.v3safe.
- Sets launcher label to Moodiary 安全版.
- Bumps the safe build to version 2.9.3+125.
- Uses the existing built-in full ZIP backup export/import path for migration.
- Adds fail-closed patch unit tests and migration contract checks.
- Adds a Windows key-generation helper and a CI signing-secret contract.
- Requires a persistent signing certificate fingerprint before APK delivery.
- Keeps cn.yooss.moodiary.v3dev unchanged and separately installed.

## Not yet complete

- User must create the new JKS once and add the four documented GitHub Actions
  secrets. This cannot be done by the workflow or by committing a private key.
- Full CI must pass on this branch.
- After secrets are configured, build and verify the signed ARM64 APK.
- Device acceptance on the user's Xiaomi 14 Pro remains pending.
- User must export a full ZIP from the old app and import it into the safe app;
  the actual personal data transfer must be verified on-device.

## Data-safety invariants

- Never uninstall, overwrite, clear storage, or reset the old app.
- Never change the old package ID to force an update.
- Never store a keystore or password in Git.
- Do not publish an APK when the signer fingerprint is missing or mismatched.
- The built-in backup ZIP includes diaries and referenced media but does not
  migrate app preferences or device-specific sync credentials.
