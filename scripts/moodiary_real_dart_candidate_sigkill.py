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


def run():
    with tempfile.TemporaryDirectory(prefix="moodiary-real-dart-kill-") as temp:
        root = Path(temp)
        marker = root / "checkpoint.ready"
        final = root / "real-candidate.zip"
        env = os.environ.copy()
        env["MOODIARY_CANDIDATE_KILL_ROOT"] = temp
        env["MOODIARY_CANDIDATE_KILL_MARKER"] = str(marker)
        cmd = ["flutter", "test", TEST, "--plain-name", CHECKPOINT, "--reporter", "compact"]
        worker = subprocess.Popen(cmd, env=env, start_new_session=True)
        try:
            deadline = time.monotonic() + 240
            while not marker.exists():
                if worker.poll() is not None:
                    raise AssertionError(f"Dart candidate worker exited early: {worker.returncode}")
                if time.monotonic() > deadline:
                    raise AssertionError("Dart candidate checkpoint timed out")
                time.sleep(.1)
            assert marker.read_text() == "zip_assembled_not_published"
            assert not final.exists(), "final path exposed before verified publication"
            # Kill the entire Flutter/Dart process group, not just a test wrapper.
            os.killpg(worker.pid, signal.SIGKILL)
            worker.wait(timeout=15)
            assert worker.returncode != 0, "worker was not terminated"
            assert not final.exists(), "SIGKILL left a partially published final ZIP"
            quarantines = list(root.glob(".moodiary-candidate-*"))
            assert len(quarantines) == 1, "expected one abandoned private quarantine"
            pending = list(quarantines[0].rglob("pending.zip"))
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
            # Do not reuse or remove abandoned quarantine. Run a clean
            # production Dart candidate build against a fresh fake backend.
            retry = subprocess.run(
                ["flutter", "test", TEST, "--plain-name", RETRY, "--reporter", "compact"],
                timeout=240, check=False)
            assert retry.returncode == 0, "fresh verified Dart build retry failed"
            assert candidate.exists(), "retry incorrectly removed old quarantine"
            assert candidate.stat().st_size == orphan_size, "retry changed orphan ZIP size"
            assert hashlib.sha256(candidate.read_bytes()).hexdigest() == orphan_sha256, (
                "retry changed abandoned candidate ZIP bytes")
            assert list(root.glob(".moodiary-candidate-*")) == quarantines, (
                "retry created or reused an unexpected quarantine in the killed build root")
            assert not final.exists(), "retry reused an abandoned final destination"
            print("PASS real Dart candidate ZIP assembly SIGKILL; no exposed final; safe fresh retry")
        finally:
            if worker.poll() is None:
                os.killpg(worker.pid, signal.SIGKILL)
                worker.wait(timeout=15)


if __name__ == "__main__":
    run()
