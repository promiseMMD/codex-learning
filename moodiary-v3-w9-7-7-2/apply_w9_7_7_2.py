"""W9.7.7.2: OS SIGKILL crash/restart test harness; isolated only."""
from pathlib import Path
import shutil
import sys

root=Path(sys.argv[1]).resolve()
here=Path(__file__).resolve().parent
for file in (here/'overlay').rglob('*'):
    if not file.is_file():
        continue
    target=root/file.relative_to(here/'overlay')
    if target.exists():
        raise SystemExit(f'W9.7.7.2 refuses overwrite: {target}')
    target.parent.mkdir(parents=True,exist_ok=True)
    shutil.copy2(file,target)

pubspec=root/'mobile/pubspec.yaml'
before='version: 2.9.2+109'
value=pubspec.read_text(encoding='utf-8')
if value.count(before)!=1:
    raise SystemExit('W9.7.7.2 version mismatch, expected +109')
pubspec.write_text(value.replace(before,'version: 2.9.2+110',1),
                   encoding='utf-8')
print('W9.7.7.2 real SIGKILL crash harness added; no production app restore code changed.')
