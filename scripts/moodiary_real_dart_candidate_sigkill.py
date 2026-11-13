#!/usr/bin/env python3
"""Kill the real Dart candidate builder after verified ZIP assembly.

Synthetic FakeRemoteBackend only. Never uses user data, live WebDAV or APK.
Run from upstream/packages/feature/moodiary_sync after flutter pub get.
"""
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
            assert marker.read_text() == "zip_complete_not_published"
            assert not final.exists(), "final path exposed before verified publication"
            # Kill the entire Flutter/Dart process group, not just a test wrapper.
            os.killpg(worker.pid, signal.SIGKILL)
            worker.wait(timeout=15)
            assert worker.returncode != 0, "worker was not terminated"
            assert not final.exists(), "SIGKILL left a partially published final ZIP"
            quarantines = list(root.glob(".moodiary-candidate-*"))
            assert len(quarantines) == 1, "expected one abandoned private quarantine"
            candidate = quarantines[0] / "verified-candidate.zip"
            assert candidate.is_file(), "ZIP assembly checkpoint was not reached"
            with zipfile.ZipFile(candidate) as archive:
                assert archive.testzip() is None, "abandoned ZIP is corrupt"
            # Do not reuse or remove abandoned quarantine. Run a clean
            # production Dart candidate build against a fresh fake backend.
            retry = subprocess.run(
                ["flutter", "test", TEST, "--plain-name", RETRY, "--reporter", "compact"],
                timeout=240, check=False)
            assert retry.returncode == 0, "fresh verified Dart build retry failed"
            assert candidate.exists(), "retry incorrectly removed old quarantine"
            assert not final.exists(), "retry reused an abandoned final destination"
            print("PASS real Dart build SIGKILL after ZIP assembly; no exposed final; safe fresh retry")
        finally:
            if worker.poll() is None:
                os.killpg(worker.pid, signal.SIGKILL)
                worker.wait(timeout=15)


if __name__ == "__main__":
    run()
