"""W9.3: PC month editor on top of the existing authenticated v4 store.

Only adds browser assets and topic discovery routing; no historical import,
schema change, native Diary projection, or WebDAV activation.
"""
from pathlib import Path
import shutil
import sys

root = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else Path.cwd()
here = Path(__file__).resolve().parent
target = root / 'packages/feature_base/moodiary_editor/editor/lan/src'
for source in (here / 'web/src').iterdir():
    dst = target / source.name
    if not source.is_file() or dst.exists():
        raise SystemExit(f'W9.3 source missing or collision: {source.name}')
    shutil.copyfile(source, dst)

p = root / 'mobile/lib/app/home/mod_lan_service.dart'
s = p.read_text(encoding='utf-8')
old = '    if (path.startsWith(ModLanMonthHttp.prefix)) {'
new = '''    if (path == ModLanMonthHttp.topicsPath ||
        path.startsWith(ModLanMonthHttp.prefix)) {'''
if s.count(old) != 1:
    raise SystemExit('W9.3 monthly routing anchor drift')
s = s.replace(old, new, 1)
old = '打开 W7 Tiptap 富文本工作台（仅支持已验证的基础格式）'
if s.count(old) != 1:
    raise SystemExit('W9.3 workspace entry label drift')
s = s.replace(old, '打开日记与长期记录工作台', 1)
p.write_text(s, encoding='utf-8')
print('W9.3 PC month workspace and read-only topic discovery installed')
