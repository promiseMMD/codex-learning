#!/usr/bin/env python3
"""Constrain Gradle only in the ephemeral, secret-free GitHub APK workspace.

The upstream source/overlays and the persistent public source repository are
not changed. Abort if upstream changes the expected memory configuration.
"""
from pathlib import Path
import sys

UPSTREAM_ARGS = (
    "org.gradle.jvmargs=-Xmx8G -XX:MaxMetaspaceSize=4G "
    "-XX:ReservedCodeCacheSize=512m -XX:+HeapDumpOnOutOfMemoryError"
)
CI_ARGS = (
    "org.gradle.jvmargs=-Xmx2560m -XX:MaxMetaspaceSize=768m "
    "-XX:ReservedCodeCacheSize=256m"
)
CI_LIMITS = {
    "org.gradle.workers.max": "2",
    "org.gradle.parallel": "false",
    "org.gradle.vfs.watch": "false",
}


def apply_ci_limits(path: Path) -> None:
    source = path.read_text(encoding="utf-8")
    lines = source.splitlines()
    if lines.count(UPSTREAM_ARGS) != 1:
        raise ValueError(
            "Expected exactly one pinned upstream Gradle heap configuration; "
            "refusing to silently edit an unknown baseline"
        )
    for key in ("org.gradle.jvmargs", *CI_LIMITS):
        if sum(line.startswith(key + "=") for line in lines) != int(key == "org.gradle.jvmargs"):
            raise ValueError(f"Unexpected pre-existing Gradle property: {key}")
    updated = source.replace(UPSTREAM_ARGS, CI_ARGS, 1)
    if not updated.endswith("\n"):
        updated += "\n"
    updated += "".join(f"{key}={value}\n" for key, value in CI_LIMITS.items())
    path.write_text(updated, encoding="utf-8")
    print("PASS: ephemeral Gradle JVM limits (2560m heap, 768m metaspace), "
          "two workers, no parallel project builds and no VFS watcher")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit("usage: limit_gradle_ci.py <ephemeral gradle.properties>")
    apply_ci_limits(Path(sys.argv[1]))
