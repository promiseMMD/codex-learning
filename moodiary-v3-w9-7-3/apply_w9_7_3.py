"""W9.7.3: exact-source refactor + streaming sealed directory staging."""
from pathlib import Path
import hashlib
import shutil
import sys

root=Path(sys.argv[1]).resolve()
here=Path(__file__).resolve().parent
replace_name='packages/feature/moodiary_sync/lib/src/data/mod_month_verified_manifest_v1.dart'
expected_blob='8a4e92046df77b8df3994a26637512f4ebd21278'

for source in (here/'overlay').rglob('*'):
    if not source.is_file():
        continue
    relative=source.relative_to(here/'overlay')
    dest=root/relative
    if dest.exists():
        if relative.as_posix()!=replace_name:
            raise SystemExit(f'W9.7.3 refuses to overwrite: {relative}')
        raw=dest.read_bytes()
        blob=b'blob '+str(len(raw)).encode()+b'\0'+raw
        if hashlib.sha1(blob).hexdigest()!=expected_blob:
            raise SystemExit('W9.7.3 native archive verification refactor anchor drift')
    dest.parent.mkdir(parents=True,exist_ok=True)
    shutil.copy2(source,dest)

pubspec=root/'mobile/pubspec.yaml'
current=pubspec.read_text(encoding='utf-8')
old='version: 2.9.2+104'
if current.count(old)!=1:
    raise SystemExit('W9.7.3 version drift')
pubspec.write_text(current.replace(old,'version: 2.9.2+105',1),
                   encoding='utf-8')
print('W9.7.3 streaming staging and receipt refactor applied; backup/sync gates retained')
