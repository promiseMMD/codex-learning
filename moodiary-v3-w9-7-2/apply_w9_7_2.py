"""W9.7.2: staging-only native/W9 archive closure manifest and regression."""
from pathlib import Path
import shutil
import sys

root=Path(sys.argv[1]).resolve()
here=Path(__file__).resolve().parent
for source in (here/'overlay').rglob('*'):
    if source.is_file():
        destination=root/source.relative_to(here/'overlay')
        if destination.exists():
            raise SystemExit(f'W9.7.2 refuses to overwrite: {destination}')
        destination.parent.mkdir(parents=True,exist_ok=True)
        shutil.copy2(source,destination)

p=root/'mobile/pubspec.yaml'
old='version: 2.9.2+103'
text=p.read_text(encoding='utf-8')
if text.count(old)!=1:
    raise SystemExit('W9.7.2 version drift')
p.write_text(text.replace(old,'version: 2.9.2+104',1),encoding='utf-8')
print('W9.7.2: verified native/W9 bundle staging contract installed; no live backup or restore routes enabled')
