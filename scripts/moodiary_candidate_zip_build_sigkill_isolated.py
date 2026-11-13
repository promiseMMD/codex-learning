#!/usr/bin/env python3
"""Isolated ZIP construction SIGKILL contract; NOT the production Dart path.

Only temporary synthetic files. No WebDAV, application data, or APK operations.
"""
import hashlib
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import zipfile

POINTS = ("before_zip", "during_zip", "after_zip", "after_verify", "after_publish")

def sha(data):
    return hashlib.sha256(data).hexdigest()

def child(root, checkpoint):
    root = Path(root)
    source = (root / "source.bin").read_bytes()
    quarantine = root / "quarantine"
    quarantine.mkdir()
    candidate = quarantine / "candidate.zip"
    final = root / "final.zip"
    def pause(point):
        if point == checkpoint:
            (root / "ready").write_text(point)
            while True:
                time.sleep(1)
    pause("before_zip")
    with zipfile.ZipFile(candidate, "w", compression=zipfile.ZIP_STORED) as z:
        with z.open("media.bin", "w", force_zip64=True) as stream:
            for i in range(0, len(source), 65536):
                stream.write(source[i:i+65536])
                pause("during_zip")
    pause("after_zip")
    with zipfile.ZipFile(candidate) as z:
        assert z.testzip() is None
        assert sha(z.read("media.bin")) == sha(source)
    pause("after_verify")
    os.link(candidate, final)  # atomic no-clobber on same filesystem
    pause("after_publish")

def check(root, point):
    root.mkdir()
    source = os.urandom(1024 * 1024)
    (root / "source.bin").write_bytes(source)
    p = subprocess.Popen([sys.executable, __file__, "--child", str(root), point])
    try:
        deadline = time.monotonic() + 15
        while not (root / "ready").exists():
            if p.poll() is not None:
                raise AssertionError(f"worker exited: {p.returncode}")
            if time.monotonic() > deadline:
                raise AssertionError(f"timeout: {point}")
            time.sleep(.02)
        os.kill(p.pid, signal.SIGKILL)
        assert p.wait(timeout=5) == -signal.SIGKILL
        final = root / "final.zip"
        assert final.exists() == (point == "after_publish")
        assert (root / "source.bin").read_bytes() == source
        if final.exists():
            with zipfile.ZipFile(final) as z:
                assert z.testzip() is None
                assert sha(z.read("media.bin")) == sha(source)
        # A fresh retry never trusts interrupted quarantine bytes.
        retry = root / "retry.zip"
        with zipfile.ZipFile(retry, "w", compression=zipfile.ZIP_STORED) as z:
            z.writestr("media.bin", source)
        with zipfile.ZipFile(retry) as z:
            assert z.testzip() is None
            assert sha(z.read("media.bin")) == sha(source)
        if final.exists():
            try:
                os.link(retry, final)
            except FileExistsError:
                pass
            else:
                raise AssertionError("existing final overwritten")
        else:
            os.link(retry, final)
        with zipfile.ZipFile(final) as z:
            assert z.testzip() is None
            assert sha(z.read("media.bin")) == sha(source)
        print(f"PASS {point}: SIGKILL, no partial final, safe retry")
    finally:
        if p.poll() is None:
            p.kill()
            p.wait()

if __name__ == "__main__":
    if len(sys.argv) == 4 and sys.argv[1] == "--child":
        child(sys.argv[2], sys.argv[3])
    else:
        if os.name != "posix":
            raise SystemExit("POSIX required")
        with tempfile.TemporaryDirectory(prefix="moodiary-zip-sigkill-") as tmp:
            for point in POINTS:
                check(Path(tmp) / point, point)
