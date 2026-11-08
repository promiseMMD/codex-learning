"""W9.7.7.4: replace only test harness; app data and sync untouched."""
from pathlib import Path
import shutil
import sys
root=Path(sys.argv[1]).resolve()
here=Path(__file__).resolve().parent
target=root/'packages/feature/moodiary_sync/test/sync/data/harness'
old=target/'real_sigkill_orchestrator.dart'
old_child=target/'real_sigkill_slot_child.dart'
if not old.is_file() or 'W9.7.7.2: REAL Linux SIGKILL' not in old.read_text():
    raise SystemExit('Unexpected old supervisor, refuse to overwrite')
if not old_child.is_file() or 'W9.7.7.2: separate REAL OS process' not in old_child.read_text():
    raise SystemExit('Unexpected old child, refuse to overwrite')
old_child.unlink()
for file in (here/'overlay').rglob('*'):
    if file.is_file():
        dest=root/file.relative_to(here/'overlay')
        dest.parent.mkdir(parents=True,exist_ok=True)
        shutil.copy2(file,dest)
print('W9.7.7.4 Flutter-engine SIGKILL harness ready')
