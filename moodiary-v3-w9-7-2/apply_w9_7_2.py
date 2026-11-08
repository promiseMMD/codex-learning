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

# The new manifest code imports crypto directly; declare it in the sync
# package rather than relying on a transitive workspace dependency.
sync_pubspec=root/'packages/feature/moodiary_sync/pubspec.yaml'
sync_src=sync_pubspec.read_text(encoding='utf-8')
anchor='  fast_crypto: 0.0.1'
if sync_src.count(anchor)!=1:
    raise SystemExit('W9.7.2 crypto dependency anchor drift')
sync_pubspec.write_text(sync_src.replace(anchor,
    '  crypto: 3.0.7\n'+anchor,1),encoding='utf-8')

p=root/'mobile/pubspec.yaml'
old='version: 2.9.2+103'
text=p.read_text(encoding='utf-8')
if text.count(old)!=1:
    raise SystemExit('W9.7.2 version drift')
p.write_text(text.replace(old,'version: 2.9.2+104',1),encoding='utf-8')
print('W9.7.2: verified native/W9 bundle staging contract installed; no live backup or restore routes enabled')
