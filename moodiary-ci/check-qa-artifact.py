#!/usr/bin/env python3
"""Validate that Android device QA uses the exact signed candidate artifact.

This checks artifact provenance and hashes, not on-device functionality.
Formal delivery still requires the human-reviewed Android device QA gate.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import re
from pathlib import Path

EXPECTED_PACKAGE = "cn.yooss.moodiary.v3safe"
EXPECTED_VERSION_NAME = "2.9.2"
EXPECTED_VERSION_CODE = 126
EXPECTED_STATUS = "signed-QA-candidate-not-formal-release"
EXPECTED_QA = "pending"
EXPECTED_WORKFLOW_REF = "refs/heads/main"
APK_NAME = "app-v3safe-release.apk"


def require(condition: bool, message: str) -> None:
    if not condition:
        raise ValueError(message)


def require_sha(value: str, label: str) -> None:
    require(re.fullmatch(r"[0-9a-f]{40}", value) is not None, f"invalid {label}")


def require_digest(value: str, label: str) -> None:
    require(re.fullmatch(r"[0-9a-f]{64}", value) is not None, f"invalid {label}")


def read_provenance(path: Path) -> dict[str, str]:
    values: dict[str, str] = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        if line == "version: 2.9.2+126":
            continue  # Original build script appends the pubspec version.
        require("=" in line, "unrecognized build provenance line")
        key, value = line.split("=", 1)
        require(bool(re.fullmatch(r"[a-z][a-z0-9_]*", key)), "invalid provenance key")
        require(key not in values, f"duplicate provenance key: {key}")
        values[key] = value
    return values


def verify(
    directory: Path,
    candidate_run_id: str,
    tested_sha: str,
    tested_apk_sha256: str,
    current_sha: str,
) -> None:
    require(re.fullmatch(r"[1-9][0-9]*", candidate_run_id) is not None, "invalid candidate run ID")
    require_sha(tested_sha, "tested commit")
    require_sha(current_sha, "current workflow commit")
    require_digest(tested_apk_sha256, "tested APK SHA-256")
    require(tested_sha == current_sha, "tested Git SHA differs from release QA commit")

    apk = directory / APK_NAME
    require(apk.is_file() and apk.stat().st_size > 0, "candidate APK is missing/empty")
    sha_path = directory / (APK_NAME + ".sha256")
    require(sha_path.is_file(), "APK SHA-256 manifest is missing")
    sha_line = sha_path.read_text(encoding="ascii").strip()
    match = re.fullmatch(r"([0-9a-f]{64})  app-v3safe-release\.apk", sha_line)
    require(match is not None, "invalid APK sha256sum manifest")

    sha = hashlib.sha256()
    with apk.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            sha.update(block)
    actual = sha.hexdigest()
    require(actual == match.group(1), "APK bytes do not match source SHA manifest")
    require(actual == tested_apk_sha256, "APK bytes differ from the APK tested on device")

    provenance_path = directory / "BUILD-PROVENANCE.txt"
    verify_path = directory / "APK-VERIFICATION.json"
    require(provenance_path.is_file(), "build provenance is missing")
    require(verify_path.is_file(), "APK verification report is missing")
    provenance = read_provenance(provenance_path)
    report = json.loads(verify_path.read_text(encoding="utf-8"))
    require(isinstance(report, dict), "invalid APK verification JSON")

    required = {
        "source_commit": tested_sha,
        "workflow_run": candidate_run_id,
        "workflow_ref": EXPECTED_WORKFLOW_REF,
        "application_id": EXPECTED_PACKAGE,
        "version_code": str(EXPECTED_VERSION_CODE),
        "version_name": EXPECTED_VERSION_NAME,
        "artifact_status": EXPECTED_STATUS,
        "original_first_import_device_qa": EXPECTED_QA,
    }
    for key, expected in required.items():
        require(provenance.get(key) == expected, f"candidate provenance mismatch: {key}")

    require(report.get("package") == EXPECTED_PACKAGE, "candidate APK report package mismatch")
    require(str(report.get("version_code")) == str(EXPECTED_VERSION_CODE), "candidate versionCode mismatch")
    require(report.get("version_name") == EXPECTED_VERSION_NAME, "candidate versionName mismatch")
    require(report.get("artifact_status") == EXPECTED_STATUS, "candidate artifact status mismatch")
    require(report.get("original_first_import_device_qa") == EXPECTED_QA, "candidate QA status mismatch")
    require(report.get("signer_matches_persistent_safe_key") is True, "signer was not validated")
    require(report.get("parallel_install_is_safe") is True, "APK parallel-install check missing")

    signer = provenance.get("signer_certificate_sha256", "")
    require_digest(signer, "persistent signer fingerprint")
    require(report.get("signer_certificate_sha256") == signer, "signer report/provenance mismatch")
    require(report.get("expected_safe_signer_sha256") == signer, "signer does not match pinned certificate")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--artifact-dir", type=Path, required=True)
    parser.add_argument("--candidate-run-id", required=True)
    parser.add_argument("--tested-sha", required=True)
    parser.add_argument("--tested-apk-sha256", required=True)
    parser.add_argument("--current-sha", required=True)
    args = parser.parse_args()
    try:
        verify(
            args.artifact_dir,
            args.candidate_run_id,
            args.tested_sha,
            args.tested_apk_sha256,
            args.current_sha,
        )
    except (ValueError, OSError, json.JSONDecodeError) as error:
        parser.exit(2, f"APK QA EVIDENCE REJECTED: {error}\n")
    print("APK QA provenance validated; on-device acceptance remains a separate requirement.")


if __name__ == "__main__":
    main()
