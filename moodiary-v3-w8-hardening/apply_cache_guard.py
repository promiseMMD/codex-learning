"""Protect active W8 LAN upload staging against general cache cleanup.

Keep Moodiary's ordinary cache behavior untouched. Only add the one
application-owned W8 staging workspace to its protected root set.
"""
from pathlib import Path
import sys
root=Path(sys.argv[1]).resolve() if len(sys.argv)>1 else Path.cwd()
p=root/"packages/core/moodiary_files/lib/src/app_files.dart"
s=p.read_text(encoding="utf-8")
old="const {'sync-media', 'export', 'import'}.contains(name) ||"
new="const {'sync-media', 'export', 'import', 'moodiary-v3-lan-stage'}.contains(name) ||"
if s.count(old)!=1:
    raise SystemExit(f"W8.5.1 cache-protection anchor changed: {s.count(old)} matches")
p.write_text(s.replace(old,new,1),encoding="utf-8")
print("W8.5.1: active LAN uploads protected from generic cache cleanup")
