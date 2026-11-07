"""W6 overlay installer: exact-anchor edits after W5, fail on drift.

Rich writes use a dedicated endpoint and never hit the W4 textarea writer.
Neither media attachments nor monthly child records are allowed.
"""
from pathlib import Path
import sys

root=Path(sys.argv[1]) if len(sys.argv)>1 else Path(".")
source=Path(__file__).resolve().parents[0]/"overlay/mobile/lib/app/home/mod_lan_rich.dart"
target=root/"mobile/lib/app/home/mod_lan_rich.dart"
target.parent.mkdir(parents=True, exist_ok=True)
target.write_bytes(source.read_bytes())

test_source=Path(__file__).resolve().parents[0]/"overlay/mobile/test/mod_lan_rich_test.dart"
test_target=root/"mobile/test/mod_lan_rich_test.dart"
test_target.parent.mkdir(parents=True,exist_ok=True)
test_target.write_bytes(test_source.read_bytes())

p=root/"mobile/lib/app/home/mod_lan_service.dart"
s=p.read_text(encoding="utf-8")

def one(old,new):
    global s
    n=s.count(old)
    if n!=1:
        raise SystemExit(f"W6 overlay drift: anchor has {n} matches: {old[:70]!r}")
    s=s.replace(old,new,1)

one(
"import 'mod_lan_write.dart';",
"import 'mod_lan_write.dart';\nimport 'mod_lan_rich.dart';")
one(
"  ModLanWriteService get _writer => ModLanWriteService(getIt<DiaryRepository>());",
"  ModLanWriteService get _writer => ModLanWriteService(getIt<DiaryRepository>());\n  ModLanRichWriter get _richWriter => ModLanRichWriter(getIt<DiaryRepository>());")
one(
"  Future<void> _handle(HttpRequest r) async {",
"""  Map<String, Object?> _richDto(Diary d) {
    final safe = ModLanRichDocument.canEdit(d);
    return {
      'id': d.id, 'title': d.title, 'text': d.contentText,
      'revision': ModLanWriteSafety.revision(d),
      'editable': safe,
      'document': safe ? ModLanRichDocument.editableDocument(d) : null,
      'lastModified': d.lastModified.toIso8601String(),
    };
  }

  Future<void> _handle(HttpRequest r) async {""")
one(
"    if (r.method == 'POST' || r.method == 'PUT' || r.method == 'DELETE' || r.method == 'PATCH') {",
"""    if (r.method == 'GET' && path.startsWith('/api/rich/diaries/') &&
        r.uri.pathSegments.length == 4) {
      try {
        final diary = await _richWriter.load(r.uri.pathSegments[3]);
        if (ModDiary.isTopic(diary) || ModDiary.isChild(diary)) {
          throw const ModLanWriteException(409, 'long_record_write_not_ready');
        }
        await _json(r, HttpStatus.ok, _richDto(diary));
      } on ModLanWriteException catch (e) {
        await _json(r, e.status, {'error': e.code});
      }
      return;
    }
    if (r.method == 'POST' || r.method == 'PUT' || r.method == 'DELETE' || r.method == 'PATCH') {""")
one(
"        if (r.method == 'POST' && path == '/api/diaries') {",
"""        if (r.method == 'POST' && path == '/api/rich/diaries') {
          final diary = await _richWriter.create(await _readJson(r));
          await _json(r, HttpStatus.ok, _richDto(diary));
        } else if (r.method == 'PUT' && path.startsWith('/api/rich/diaries/') &&
            r.uri.pathSegments.length == 4) {
          final diary = await _richWriter.load(r.uri.pathSegments[3]);
          if (ModDiary.isTopic(diary) || ModDiary.isChild(diary)) {
            throw const ModLanWriteException(409, 'long_record_write_not_ready');
          }
          final updated = await _richWriter.update(diary.id, await _readJson(r));
          await _json(r, HttpStatus.ok, _richDto(updated));
        } else if (r.method == 'POST' && path == '/api/diaries') {""")
one(
"'mode': 'w5_autosave_safe_text_editor'",
"'mode': 'w6_rich_json_api_with_safe_text_editor'")
p.write_text(s,encoding="utf-8")
print("W6 rich data API overlay applied (schema-checked CAS only, no rich UI)")
