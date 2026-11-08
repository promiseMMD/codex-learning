"""W9.7.7: read-only orphan diagnostics. Never automatic cleanup/activation."""
from pathlib import Path
import shutil
import sys

root=Path(sys.argv[1]).resolve()
here=Path(__file__).resolve().parent
for source in (here/'overlay').rglob('*'):
    if source.is_file():
        dest=root/source.relative_to(here/'overlay')
        if dest.exists():
            raise SystemExit(f'W9.7.7 refuses to overwrite: {dest}')
        dest.parent.mkdir(parents=True,exist_ok=True)
        shutil.copy2(source,dest)

pubspec=root/'mobile/pubspec.yaml'
old='version: 2.9.2+108'
value=pubspec.read_text(encoding='utf-8')
if value.count(old)!=1:
    raise SystemExit('W9.7.7 pinned developer version is not +108')
pubspec.write_text(value.replace(old,'version: 2.9.2+109',1),encoding='utf-8')
print('W9.7.7 read-only orphan inspector installed. No real user data paths enabled.')
