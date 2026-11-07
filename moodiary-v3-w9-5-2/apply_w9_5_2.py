"""W9.5.2: native daily routes, protected quick-append sheet and stable order."""
from pathlib import Path
import base64
import io
import shutil
import sys
import zipfile

root = Path(sys.argv[1]).resolve()
here = Path(__file__).resolve().parent
for source in (here / 'overlay').rglob('*'):
    if source.is_file():
        target = root / source.relative_to(here / 'overlay')
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, target)

pub = root / 'mobile/pubspec.yaml'
text = pub.read_text()
if 'version: 2.9.2+101' not in text:
    assert text.count('version: 2.9.2+100') == 1
    pub.write_text(text.replace('version: 2.9.2+100', 'version: 2.9.2+101'))

generated = here / 'generated-i18n.b64'
if generated.exists():
    with zipfile.ZipFile(io.BytesIO(base64.b64decode(generated.read_bytes()))) as z:
        assert set(z.namelist()) == {'strings.g.dart','strings_en.g.dart','strings_zh.g.dart'}
        assert z.testzip() is None
        target = root / 'packages/foundation/moodiary_i18n/lib/i18n'
        for name in z.namelist():
            (target / name).write_bytes(z.read(name))
print('Applied W9.5.2 daily routes and created-time ordering; no Diary projection or sync-format change')
