"""W9.8.4.4: wire ZIP cold restore into the isolated V2 generation slot."""
from pathlib import Path
import hashlib
import shutil
import sys

root=Path(sys.argv[1]).resolve()
here=Path(__file__).resolve().parent
replaceable_test=Path(
    'packages/feature/moodiary_sync/test/sync/data/'
    'mod_month_isolated_restore_v2_test.dart'
)
expected_base_blob='6c02ed6d4d0351e5ee72005ddc8e8826ed30606a'

def git_blob_sha(data: bytes) -> str:
    header=f'blob {len(data)}\0'.encode('ascii')
    return hashlib.sha1(header+data).hexdigest()

for source in (here/'overlay').rglob('*'):
    if not source.is_file():
        continue
    relative=source.relative_to(here/'overlay')
    dest=root/relative
    dest.parent.mkdir(parents=True,exist_ok=True)
    if dest.exists():
        if relative!=replaceable_test:
            raise SystemExit('W9.8.4.4 overlay collision: '+str(dest))
        existing=dest.read_bytes()
        desired=source.read_bytes()
        actual=git_blob_sha(existing)
        if existing==desired:
            print('ALREADY APPLIED: '+str(relative))
            continue
        if actual!=expected_base_blob:
            raise SystemExit(
                'W9.8.4.4 test baseline mismatch; refusing replacement: '
                +str(dest)+' ('+actual+')'
            )
        shutil.copyfile(source,dest)
        print('PATCHED VERIFIED W9.8.4.2 TEST BASELINE: '+str(relative))
    else:
        shutil.copyfile(source,dest)
        print('ADDED: '+str(relative))

pub=root/'mobile/pubspec.yaml'
data=pub.read_text(encoding='utf-8')
old='version: 2.9.2+116'
if data.count(old)!=1:
    raise SystemExit('W9.8.4.4 version anchor mismatch')
pub.write_text(data.replace(old,'version: 2.9.2+117',1),encoding='utf-8')
print('W9.8.4.4 ZIP -> isolated V2 generation integration staged')
