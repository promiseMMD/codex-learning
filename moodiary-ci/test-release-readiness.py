#!/usr/bin/env python3
"""Fail-closed regression for QA-candidate vs formal APK release separation."""
import subprocess
import sys
from pathlib import Path

script = Path(__file__).with_name("check-release-readiness.py")


def run(*args: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [sys.executable, str(script), *args],
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )


def main() -> None:
    release = run()
    assert release.returncode == 2, release
    assert "APK PUBLIC RELEASE BLOCKED" in release.stdout
    assert "original-to-modded first import and device QA" in release.stdout
    assert "complete custom-data migration" not in release.stdout

    candidate = run("--qa-candidate")
    assert candidate.returncode == 0, candidate
    assert "QA CANDIDATE ONLY" in candidate.stdout
    assert "no formal release" in candidate.stdout
    assert "readiness gate passed" not in candidate.stdout

    for option in ("--release", "--qa", "--qa-candidate=1"):
        rejected = run(option)
        assert rejected.returncode != 0, option
        assert "QA CANDIDATE ONLY" not in rejected.stdout

    print("Release remains blocked; signed QA candidate is explicitly not a release.")


if __name__ == "__main__":
    main()
