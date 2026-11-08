"""W9.8.4.1 native+GraphV2+media full-closure staging, NOT live restore.

Packages audited V1 native/media closure under a V2 day-graph envelope.
Changes nothing to production backup, ZIP, WebDAV, or live user database.
"""
from pathlib import Path
import shutil
import sys

root=Path(sys.argv[1]).resolve()
here=Path(__file__).resolve().parent
for file in (here/'overlay').rglob('*'):
    if file.is_file():
        dest=root/file.relative_to(here/'overlay')
        if dest.exists():
            raise SystemExit('Refuse W9.8.4.1 overlay collision: '+str(dest))
        dest.parent.mkdir(parents=True,exist_ok=True)
        shutil.copyfile(file,dest)

pub=root/'mobile/pubspec.yaml'
text=pub.read_text(encoding='utf-8')
old='version: 2.9.2+113'
if text.count(old)!=1:
    raise SystemExit('W9.8.4.1 version anchor mismatch')
pub.write_text(text.replace(old,'version: 2.9.2+114',1),encoding='utf-8')
print('W9.8.4.1 V2 native/day graph/media closure and stream staging installed')
