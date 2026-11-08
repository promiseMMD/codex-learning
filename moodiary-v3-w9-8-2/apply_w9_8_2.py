"""W9.8.2: read-only day cards in ordinary Diary home.

This overlay deliberately creates NO native Diary row or legacy archive item.
Keeps W9 structured CAS, local-only flags and backup preflight unchanged.
"""
from pathlib import Path
import shutil
import sys

root = Path(sys.argv[1]).resolve()
here = Path(__file__).resolve().parent
for file in (here / "overlay").rglob("*"):
    if file.is_file():
        dest = root / file.relative_to(here / "overlay")
        if dest.exists():
            raise SystemExit("W9.8.2 overlay collision: " + str(dest))
        dest.parent.mkdir(parents=True,exist_ok=True)
        shutil.copyfile(file,dest)

def one(relative, old, new):
    dest = root / relative
    source = dest.read_text(encoding="utf-8")
    if source.count(old) != 1:
        raise SystemExit("W9.8.2 source drift: " + relative + " " + old[:90])
    dest.write_text(source.replace(old,new,1),encoding="utf-8")

home = "mobile/lib/app/home/diary_home_page.dart"
one(home,
    "import 'package:mui/mui.dart';",
    "import 'package:mui/mui.dart';\n\nimport 'mod_day_home_panel.dart';")
one(home,
    "    final body = _buildDiaryView(filter);",
    """    final ordinaryBody = _buildDiaryView(filter);
    // W9 daily blocks stay out of the native Diary model until the
    // complete block/history/media archive can be safely restored.
    final body = filter.isAll && !selecting
        ? Column(children: [
            const ModDayHomePanel(),
            Expanded(child: ordinaryBody),
          ])
        : ordinaryBody;""")

one("mobile/pubspec.yaml","version: 2.9.2+111","version: 2.9.2+112")
print("W9.8.2 home daily cards and protected dedicated route installed")
