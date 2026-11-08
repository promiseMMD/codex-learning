"""W9.7.1 portable structured graph snapshot + isolated restore testing only."""
from pathlib import Path
import shutil
import sys

root=Path(sys.argv[1]).resolve()
here=Path(__file__).resolve().parent

for source in (here/'overlay').rglob('*'):
    if source.is_file():
        dest=root/source.relative_to(here/'overlay')
        if dest.exists():
            raise SystemExit(f'W9.7 refuses overwrite: {dest}')
        dest.parent.mkdir(parents=True,exist_ok=True)
        shutil.copy2(source,dest)

def patch(relative,old,new):
    path=root/relative
    text=path.read_text(encoding='utf-8')
    if text.count(old)!=1:
        raise SystemExit(f'W9.7 anchor mismatch: {relative}: {old[:90]}')
    path.write_text(text.replace(old,new,1),encoding='utf-8')

patch('packages/feature_base/moodiary_data/lib/moodiary_data.dart',
      "export 'src/mod_month_archive_gate.dart';",
      "export 'src/mod_month_archive_gate.dart';\n"
      "export 'src/mod_month_graph_archive_v1.dart';")
patch('mobile/pubspec.yaml','version: 2.9.2+102','version: 2.9.2+103')
print('W9.7.1: graph exporter/validator and isolated restore test API installed')
