#!/usr/bin/env python3
"""Kill the real Dart candidate builder after candidate ZIP assembly.

Synthetic FakeRemoteBackend only. Never uses user data, live WebDAV or APK.
Run from upstream/packages/feature/moodiary_sync after flutter pub get.
"""
import hashlib
import os
from pathlib import Path
import signal
import subprocess
import tempfile
import time
import zipfile

TEST = "test/sync/data/mod_month_remote_chunked_candidate_v1_test.dart"
CHECKPOINT = "external SIGKILL checkpoint inside actual Dart candidate build"
RETRY = "ancestor and descendant histories create a full verified ZIP with"


def run(stage):
    with tempfile.TemporaryDirectory(prefix="moodiary-real-dart-kill-") as temp:
        root = Path(temp)
        marker = root / "checkpoint.ready"
        final = root / "real-candidate.zip"
        env = os.environ.copy()
        env["MOODIARY_CANDIDATE_KILL_ROOT"] = temp
        env["MOODIARY_CANDIDATE_KILL_MARKER"] = str(marker)
        env["MOODIARY_CANDIDATE_KILL_STAGE"] = stage
        cmd = ["flutter", "test", TEST, "--plain-name", (
            "external SIGKILL after actual Dart candidate publication"
            if stage == "published" else CHECKPOINT), "--reporter", "compact"]
        worker = subprocess.Popen(cmd, env=env, start_new_session=True)
        try:
            deadline = time.monotonic() + 240
            while not marker.exists():
                if worker.poll() is not None:
                    raise AssertionError(f"Dart candidate worker exited early: {worker.returncode}")
                if time.monotonic() > deadline:
                    raise AssertionError("Dart candidate checkpoint timed out")
                time.sleep(.1)
            assert marker.read_text() == (
                "verified_published_before_sigkill" if stage == "published" else
                "zip_readback_extracted_not_published" if stage == "readback" else
                "zip_assembled_not_published")
            assert final.exists() if stage == "published" else not final.exists(), (
                "incorrect final ZIP visibility at checkpoint")
            # Kill the entire Flutter/Dart process group, not just a test wrapper.
            os.killpg(worker.pid, signal.SIGKILL)
            worker.wait(timeout=15)
            assert worker.returncode != 0, "worker was not terminated"
            if stage == "published":
                assert final.is_file(), "published candidate lost after SIGKILL"
                with zipfile.ZipFile(final) as archive:
                    names = archive.namelist()
                    assert names, "published candidate has no ZIP entries"
                    assert len(names) == len(set(names)), (
                        "published candidate has duplicate ZIP entries")
                    assert all(
                        name and not name.startswith("/") and
                        ".." not in Path(name).parts and chr(92) not in name
                        for name in names
                    ), "published candidate has unsafe ZIP entry names"
                    assert archive.testzip() is None, (
                        "published candidate is incomplete after SIGKILL")
                published_hash = hashlib.sha256(final.read_bytes()).hexdigest()
                published_size = final.stat().st_size
                assert not list(root.glob(".moodiary-candidate-*")), (
                    "completed build left a staging quarantine")
                # A separate Dart process must attempt the SAME final path.
                # It must reject the published file before any remote read.
                restart_env = os.environ.copy()
                restart_env["MOODIARY_CANDIDATE_KILL_ROOT"] = temp
                restart_env["MOODIARY_CANDIDATE_KILL_STAGE"] = "restart"
                retry = subprocess.run(
                    ["flutter", "test", TEST, "--plain-name",
                     "external restart rejects published candidate before remote reads",
                     "--reporter", "compact"],
                    env=restart_env, timeout=240, check=False)
                assert retry.returncode == 0, "cross-process published ZIP restart safety failed"
                assert final.stat().st_size == published_size, (
                    "retry changed already published candidate size")
                assert hashlib.sha256(final.read_bytes()).hexdigest() == published_hash, (
                    "retry modified already published candidate")
                with zipfile.ZipFile(final) as archive:
                    assert archive.testzip() is None, (
                        "published candidate failed CRC after retry")
                print("PASS real Dart post-publication SIGKILL; verified final preserved")
                return
            assert not final.exists(), "SIGKILL left a partially published final ZIP"
            quarantines = list(root.glob(".moodiary-candidate-*"))
            assert len(quarantines) == 1, "expected one abandoned private quarantine"
            pending = list(quarantines[0].rglob("verified-candidate.zip" if stage == "readback" else "pending.zip"))
            assert len(pending) == 1, "expected one isolated assembled pending ZIP"
            candidate = pending[0]
            assert candidate.is_file(), "ZIP assembly checkpoint was not reached"
            # Validate the interrupted archive's central directory and entries,
            # not merely its existence. The private orphan must be a complete
            # assembled ZIP, never an accidentally exposed final artifact.
            with zipfile.ZipFile(candidate) as archive:
                names = archive.namelist()
                assert names, "assembled ZIP has no entries"
                assert len(names) == len(set(names)), "assembled ZIP has duplicate entries"
                assert all(
                    name and not name.startswith("/") and
                    ".." not in Path(name).parts and "\\" not in name
                    for name in names
                ), "assembled ZIP has unsafe entry names"
                assert archive.testzip() is None, "abandoned ZIP is corrupt"
            orphan_sha256 = hashlib.sha256(candidate.read_bytes()).hexdigest()
            orphan_size = candidate.stat().st_size
            # Restart in a separate Dart process at the EXACT same absent
            # destination. The orphan quarantine must remain untouched.
            restart_env = os.environ.copy()
            restart_env["MOODIARY_CANDIDATE_KILL_ROOT"] = temp
            restart_env["MOODIARY_CANDIDATE_KILL_STAGE"] = "restart-absent"
            retry = subprocess.run(
                ["flutter", "test", TEST, "--plain-name",
                 "external restart rebuilds absent candidate without touching orphan",
                 "--reporter", "compact"],
                env=restart_env, timeout=240, check=False)
            assert retry.returncode == 0, "same-path cross-process Dart recovery failed"
            assert final.is_file(), "restart did not publish the original destination"
            with zipfile.ZipFile(final) as archive:
                assert archive.testzip() is None, "recovered ZIP failed CRC"
            assert candidate.exists(), "retry incorrectly removed old quarantine"
            assert candidate.stat().st_size == orphan_size, "retry changed orphan ZIP size"
            assert hashlib.sha256(candidate.read_bytes()).hexdigest() == orphan_sha256, (
                "retry changed abandoned candidate ZIP bytes")
            assert list(root.glob(".moodiary-candidate-*")) == quarantines, (
                "retry created or reused an unexpected quarantine in the killed build root")
            assert final.exists(), "same-path restart lost recovered final ZIP"
            print(f"PASS real Dart candidate ZIP {stage} SIGKILL; same-path recovery preserved orphan")
        finally:
            if worker.poll() is None:
                os.killpg(worker.pid, signal.SIGKILL)
                worker.wait(timeout=15)


if __name__ == "__main__":
    for stage in ("assembly", "readback", "published"):
        run(stage)
