"""W9.8.4.3 isolated V2 dual-generation recovery slot + real SIGKILL.
Distinct V2 identity, cold restore marker, nested GraphV2 and file SHA256.
Test-only generation pointers; never touch the live app DB or WebDAV store.
"""
from pathlib import Path
import shutil
import sys
root=Path(sys.argv[1]).resolve()
here=Path(__file__).resolve().parent
for file in (here/'overlay').rglob('*'):
    if file.is_file():
        target=root/file.relative_to(here/'overlay')
        if target.exists():
            raise SystemExit('W9.8.4.3 overlay collision: '+str(target))
        target.parent.mkdir(parents=True,exist_ok=True)
        shutil.copyfile(file,target)
pub=root/'mobile/pubspec.yaml'
data=pub.read_text(encoding='utf-8')
old='version: 2.9.2+115'
if data.count(old)!=1:
    raise SystemExit('W9.8.4.3 version drift')
pub.write_text(data.replace(old,'version: 2.9.2+116',1),encoding='utf-8')
print('W9.8.4.3 V2 isolated slot and SIGKILL suite installed')
