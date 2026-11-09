#!/usr/bin/env python3
"""Fail-closed APK release gate for full Moodiary data migration."""

# Keep False until one production backup package contains ordinary Diary data,
# media, all W9 month/day graph tables and a tested live migration import.
# A test-only isolated restore or current-head LAN snapshot is not sufficient.
MIGRATION_READY = False

BLOCKERS = (
    "ordinary LocalArchive ZIP omits custom W9 month/day tables",
    "W9 graph export/ZIP/restore is not wired to the production backup UI",
    "the old installed APK cannot be updated with a new exporter because its signing key is unavailable",
    "the current LAN month API returns latest heads, not full revision/operation history",
    "production migration import and end-to-end device verification are pending",
)


def main() -> None:
    if not MIGRATION_READY:
        print("APK RELEASE BLOCKED: complete custom-data migration is not production-ready.")
        for item in BLOCKERS:
            print(" - " + item)
        raise SystemExit(2)
    print("Full ordinary + W9 migration readiness gate passed.")


if __name__ == "__main__":
    main()
