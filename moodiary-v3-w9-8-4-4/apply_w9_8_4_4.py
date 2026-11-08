"""W9.8.4.4: wire ZIP cold restore into the isolated V2 generation slot."""
from pathlib import Path
import shutil
import sys

root=Path(sys.argv[1]).resolve()
here=Path(__file__).resolve().parent
for source in (here/'overlay').rglob('*'):
    if source.is_file():
        dest=root/source.relative_to(here/'overlay')
        if dest.exists():
            raise SystemExit('W9.8.4.4 overlay collision: '+str(dest))
        dest.parent.mkdir(parents=True,exist_ok=True)
        shutil.copyfile(source,dest)

pub=root/'mobile/pubspec.yaml'
data=pub.read_text(encoding='utf-8')
old='version: 2.9.2+116'
if data.count(old)!=1:
    raise SystemExit('W9.8.4.4 version anchor mismatch')
pub.write_text(data.replace(old,'version: 2.9.2+117',1),encoding='utf-8')
print('W9.8.4.4 ZIP -> isolated V2 generation integration staged')
