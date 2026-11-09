#!/usr/bin/env python3
"""Temporary W9.8.4.15 source inspection; prints only ModDiary classifier."""
from pathlib import Path
import zipfile

archive = Path("/tmp/moodiary-v3-w1.zip")
if not archive.is_file():
    raise SystemExit("W1 source archive is missing")
with zipfile.ZipFile(archive) as bundle:
    candidates = [name for name in bundle.namelist()
                  if name.endswith("/mod_continuous.dart")
                  or name == "mobile/lib/app/home/mod_continuous.dart"]
    if len(candidates) != 1:
        raise SystemExit("Expected exactly one mod_continuous.dart: " + repr(candidates))
    source = bundle.read(candidates[0]).decode("utf-8")
    lines = source.splitlines()
    matches = [i for i, line in enumerate(lines) if "class ModDiary" in line]
    if len(matches) != 1:
        raise SystemExit("ModDiary class not found uniquely")
    start = matches[0]
    end = min(len(lines), start + 180)
    print("=== W1 ModDiary classifier source ===")
    for index in range(start, end):
        print(f"{index + 1}: {lines[index]}")
    print("=== end ModDiary classifier source ===")
