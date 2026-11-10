#!/usr/bin/env python3
"""Fail-closed APK release gate for original Moodiary -> final mod build."""

# Confirmed user scope (2026-11-10): ALL existing notes are in original Moodiary.
# The interim modified APK has no notes, so no modified-build W9 history needs
# migrating. An ordinary original-app native backup is a valid source, not an
# incomplete historical-migration payload. Existing full-W9 support stays intact
# for future local backups but is NOT a prerequisite for this user's migration.
# Keep False until a real original-version export, matching target import,
# and parallel-install device acceptance pass. Do not wipe the original app.
MIGRATION_READY = False

BLOCKERS = (
    "original installed Moodiary version and its native backup format must be verified",
    "original ZIP -> final app media, metadata and note round-trip device acceptance pending",
    "final build must have a persistent signing identity and pass Android installation tests",
)


def main() -> None:
    if not MIGRATION_READY:
        print("APK RELEASE BLOCKED: complete custom-data migration is not production-ready.")
        for item in BLOCKERS:
            print(" - " + item)
        raise SystemExit(2)
    print("Original Moodiary to final modified app migration readiness gate passed.")


if __name__ == "__main__":
    main()
