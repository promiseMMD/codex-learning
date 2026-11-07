"""W9.2 authenticated monthly revision API, applied after the W9.1 store.

No old Diary conversion, implicit month projection, or sync changes.
"""
from pathlib import Path
import shutil
import sys

root = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else Path.cwd()
here = Path(__file__).resolve().parent
for relative in [
    'mobile/lib/app/home/mod_lan_month_http.dart',
    'mobile/test/mod_lan_month_http_test.dart',
    'mobile/test/mod_month_disk_test.dart',
]:
    source = here / 'overlay' / relative
    target = root / relative
    if target.exists() or not source.is_file():
        raise SystemExit(f'W9.2 source missing or collision: {relative}')
    target.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(source, target)

p = root / 'mobile/lib/app/home/mod_lan_service.dart'
s = p.read_text(encoding='utf-8')
def one(a, b):
    global s
    if s.count(a) != 1:
        raise SystemExit(f'W9.2 LAN anchor drift: {s.count(a)}, {a[:90]!r}')
    s = s.replace(a, b, 1)

one("import 'mod_lan_write.dart';", "import 'mod_lan_write.dart';\n"
    "import 'mod_month_store.dart';\nimport 'mod_lan_month_http.dart';")
one("    if (r.method == 'GET' && path == '/api/events') {", """    if (path.startsWith(ModLanMonthHttp.prefix)) {
      final months = ModLanMonthHttp(
        store: ModMonthStore(getIt<MoodiaryDatabase>()),
        repository: getIt<DiaryRepository>(),
        onCommitted: (topicId) => _hub.publish(
          kind: 'updated', id: topicId, source: 'local'),
      );
      await months.tryHandle(r,
        authority: '${_localIp ?? ''}:$_port',
        csrfToken: session.csrf,
        isSessionActive: () => _sessions[session.id] == session &&
            !session.expired(DateTime.now()) && isRunning,
      );
      return;
    }
    if (r.method == 'GET' && path == '/api/events') {""")
p.write_text(s, encoding='utf-8')
print('W9.2 monthly HTTP revision API installed after session/origin gates')
