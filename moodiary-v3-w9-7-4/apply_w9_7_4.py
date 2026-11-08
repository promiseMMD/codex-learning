"""W9.7.4: isolate and verify ZIP packaging of the W9.7.3 sealed tree."""
from pathlib import Path
import shutil
import sys

root=Path(sys.argv[1]).resolve()
here=Path(__file__).resolve().parent
for src in (here/'overlay').rglob('*'):
    if src.is_file():
        dest=root/src.relative_to(here/'overlay')
        if dest.exists():
            raise SystemExit(f'W9.7.4 refuses to overwrite: {dest}')
        dest.parent.mkdir(parents=True,exist_ok=True)
        shutil.copy2(src,dest)

pubspec=root/'mobile/pubspec.yaml'
content=pubspec.read_text(encoding='utf-8')
old='version: 2.9.2+105'
if content.count(old)!=1:
    raise SystemExit('W9.7.4 version anchor drift')
pubspec.write_text(content.replace(old,'version: 2.9.2+106',1),
                   encoding='utf-8')
print('W9.7.4: ZIP preflight, quarantined readback and tests installed; user-facing backup and WebDAV unchanged')
