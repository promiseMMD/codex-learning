"""W9.7.5 isolated multi-domain restore — opt-in test-only API, no live import."""
from pathlib import Path
import shutil
import sys

root=Path(sys.argv[1]).resolve()
here=Path(__file__).resolve().parent
for source in (here/'overlay').rglob('*'):
    if source.is_file():
        target=root/source.relative_to(here/'overlay')
        if target.exists():
            raise SystemExit(f'W9.7.5 refuses overwrite: {target}')
        target.parent.mkdir(parents=True,exist_ok=True)
        shutil.copy2(source,target)

pubspec=root/'mobile/pubspec.yaml'
data=pubspec.read_text(encoding='utf-8')
old='version: 2.9.2+106'
if data.count(old)!=1:
    raise SystemExit('W9.7.5 version anchor drift')
pubspec.write_text(data.replace(old,'version: 2.9.2+107',1),
                   encoding='utf-8')
print('W9.7.5 isolated ZIP/SQLite + media restore installed; no real backup, WebDAV or live data paths activated')
