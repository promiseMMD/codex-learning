"""W9.7.6: private-generation crash recovery, never live DB activation."""
from pathlib import Path
import shutil
import sys

root=Path(sys.argv[1]).resolve()
here=Path(__file__).resolve().parent
for file in (here/'overlay').rglob('*'):
    if not file.is_file():
        continue
    dest=root/file.relative_to(here/'overlay')
    if dest.exists():
        raise SystemExit(f'W9.7.6 refuses to overwrite: {dest}')
    dest.parent.mkdir(parents=True,exist_ok=True)
    shutil.copy2(file,dest)

version=root/'mobile/pubspec.yaml'
old='version: 2.9.2+107'
text=version.read_text(encoding='utf-8')
if text.count(old)!=1:
    raise SystemExit('W9.7.6 build version drift')
version.write_text(text.replace(old,'version: 2.9.2+108',1),
                   encoding='utf-8')
print('W9.7.6 private generation slot staged; no user-facing backup, restore, or WebDAV changes')
