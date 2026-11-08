"""W9.8.4.2 — V2 ZIP and cold isolated database+media recovery.

The ZIP stage uses V2 schema and media closure. Restored data is placed in
an entirely new independent filesystem tree; neither ordinary Diaries in the
running app nor production sync/restore endpoints are ever accessed.
"""
from pathlib import Path
import shutil
import sys

root=Path(sys.argv[1]).resolve()
here=Path(__file__).resolve().parent
for source in (here/'overlay').rglob('*'):
    if source.is_file():
        dest=root/source.relative_to(here/'overlay')
        if dest.exists():
            raise SystemExit('W9.8.4.2 refuse overlay collision: '+str(dest))
        dest.parent.mkdir(parents=True,exist_ok=True)
        shutil.copyfile(source,dest)

pub=root/'mobile/pubspec.yaml'
contents=pub.read_text(encoding='utf-8')
old='version: 2.9.2+114'
if contents.count(old)!=1:
    raise SystemExit('W9.8.4.2 version anchor mismatch')
pub.write_text(contents.replace(old,'version: 2.9.2+115',1),encoding='utf-8')
print('W9.8.4.2 sealed V2 ZIP + isolated V2 native, day graph and media cold restore staged')
