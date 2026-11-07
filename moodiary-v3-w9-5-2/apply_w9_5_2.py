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

def patch(relative, old, new):
    path = root / relative
    source = path.read_text()
    if new in source:
        return
    assert source.count(old) == 1, (relative, old)
    path.write_text(source.replace(old, new, 1))

continuous = 'mobile/lib/app/home/mod_continuous.dart'
patch(continuous, "import 'mod_month_page.dart';", "import 'mod_month_page.dart';\nimport 'mod_month_composer.dart';\nimport 'package:moodiary_i18n/moodiary_i18n.dart';")
patch(continuous, '  List<Diary> _pins = const [];', '  List<Diary> _pins = const [];\n  bool _adding = false;')
patch(continuous, '''? Navigator.of(context).push(MaterialPageRoute<void>(
                        builder: (_) => ModTopicPage(topicId: d.id, append: true)))''',
      '? _quickAppend(context, d.id)')
patch(continuous, '  void _open(BuildContext context, Diary d) {', '''  Future<void> _quickAppend(BuildContext context, String topicId) async {
    if (_adding) return;
    _adding = true;
    try {
      final now = DateTime.now();
      final saved = await showModMonthComposer(context: context,
        repository: ModNativeMonthRepository(
          store: ModMonthStore(getIt<MoodiaryDatabase>()),
          diaries: ModDiary.repo,
          onCommitted: ModLanServer.instance.notifyMonthCommitted),
        topicId: topicId, monthKey: modMonthKey(now), initialDayKey: modDayKey(now));
      if (saved != null && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(context.l10n.month.savedLocal)));
      }
    } finally { _adding = false; }
  }

  void _open(BuildContext context, Diary d) {''')
print('Applied W9.5.2 daily routes and created-time ordering; no Diary projection or sync-format change')
