#!/usr/bin/env python3
"""Exercise the actual APK signing preflight shell block without exposing secrets."""
from __future__ import annotations

import os
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github/workflows/moodiary-v3-full-ci.yml"
START = "      - name: Fail early when persistent Android signing secrets are missing"
END = "      - name: Prepare pinned upstream and apply ALL V3 overlays"
SECRETS = (
    "MOODIARY_SAFE_KEYSTORE_BASE64",
    "MOODIARY_SAFE_STORE_PASSWORD",
    "MOODIARY_SAFE_KEY_PASSWORD",
    "MOODIARY_SAFE_CERT_SHA256",
)


def extract_script() -> str:
    source = WORKFLOW.read_text(encoding="utf-8")
    if source.count(START) != 1 or source.count(END) != 1:
        raise SystemExit("Signing preflight workflow step is missing or duplicated")
    block = source[source.index(START):source.index(END)]
    lines = block.splitlines()
    run_indexes = [i for i, line in enumerate(lines) if line == "        run: |"]
    if len(run_indexes) != 1:
        raise SystemExit("Signing preflight must contain exactly one literal run block")
    script_lines = []
    for line in lines[run_indexes[0] + 1:]:
        if line.startswith("          "):
            script_lines.append(line[10:])
        elif not line.strip():
            script_lines.append("")
        else:
            break
    script = "\n".join(script_lines).strip()
    if "set -euo pipefail" not in script or not script:
        raise SystemExit("Signing preflight shell block is malformed")
    return script


def execute(script: str, env: dict[str, str]) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["bash", "-c", script],
        env=env,
        text=True,
        capture_output=True,
        timeout=10,
        check=False,
    )


def main() -> None:
    script = extract_script()
    placeholders = {name: "test-only-not-a-real-secret-" + name for name in SECRETS}

    # Check each secret independently so the first missing item cannot hide
    # a broken check for any of the remaining three.
    for missing in SECRETS:
        env = os.environ.copy()
        env.update(placeholders)
        env.pop(missing, None)
        result = execute(script, env)
        output = result.stdout + result.stderr
        if result.returncode == 0:
            raise SystemExit(f"preflight unexpectedly accepted missing {missing}")
        if f"Missing required GitHub Actions signing secret: {missing}" not in output:
            raise SystemExit(f"preflight did not identify missing secret {missing}")
        if any(value in output for value in placeholders.values()):
            raise SystemExit("preflight leaked a signing secret value")

    env = os.environ.copy()
    env.update(placeholders)
    result = execute(script, env)
    output = result.stdout + result.stderr
    if result.returncode != 0:
        raise SystemExit("preflight rejected four present placeholder values: " + output)
    if "Persistent signing configuration exists" not in output:
        raise SystemExit("preflight success message is missing")
    if any(value in output for value in placeholders.values()):
        raise SystemExit("preflight leaked a signing secret value")

    print("PASS: each of four missing signing secrets fails early and is named")
    print("PASS: four present values pass presence-only preflight")
    print("PASS: no signing secret values are written to output")
    print("Certificate fingerprint and keystore validation remain in the later signer step")


if __name__ == "__main__":
    main()
