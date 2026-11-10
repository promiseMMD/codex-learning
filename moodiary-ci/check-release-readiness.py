#!/usr/bin/env python3
"""Fail-closed APK release gate for original Moodiary -> final mod build."""

# D02: the user approved this permanent package identity on 2026-11-10.
PERMANENT_APPLICATION_ID = "cn.yooss.moodiary.v3safe"

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


def main(argv: list[str] | None = None) -> None:
    """Keep QA artifact generation separate from formal production authorization."""
    import sys

    args = sys.argv[1:] if argv is None else argv
    if args == ["--qa-candidate"]:
        # The package identity is permanent; this option only marks the artifact
        # as a QA candidate until real migration and device acceptance pass.
        print(
            "QA CANDIDATE ONLY: permanent applicationId="
            + PERMANENT_APPLICATION_ID
            + "; no formal release or user-data migration authorized."
        )
        return
    if args:
        raise SystemExit("Unknown release-readiness option; refusing to proceed")
    print("Permanent Android applicationId (D02 user-approved): " + PERMANENT_APPLICATION_ID)
    if not MIGRATION_READY:
        print("APK PUBLIC RELEASE BLOCKED: official original-to-modded first import and device QA are not verified.")
        for item in BLOCKERS:
            print(" - " + item)
        raise SystemExit(2)
    print("Original Moodiary to final modified app migration readiness gate passed.")


if __name__ == "__main__":
    main()
