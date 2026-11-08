"""W9.8.3: checksum-verified structured graph V2, isolated restore only.

V1 archive remains fail-closed if day mapping exists. V2 is NOT wired to
production backup, WebDAV, native Diary creation or live restore.
"""
from pathlib import Path
import shutil
import sys

root=Path(sys.argv[1]).resolve()
here=Path(__file__).resolve().parent
for file in (here/'overlay').rglob('*'):
    if file.is_file():
        target=root/file.relative_to(here/'overlay')
        if target.exists():
            raise SystemExit('Refuse W9.8.3 overlay collision: '+str(target))
        target.parent.mkdir(parents=True,exist_ok=True)
        shutil.copyfile(file,target)

def patch(relative,old,new):
    p=root/relative
    data=p.read_text(encoding='utf-8')
    if data.count(old)!=1:
        raise SystemExit('W9.8.3 anchor drift '+relative+': '+old[:100])
    p.write_text(data.replace(old,new,1),encoding='utf-8')

file='packages/feature_base/moodiary_data/lib/src/mod_month_graph_archive_v1.dart'
patch(file,
      'static Future<void> _schema(MoodiaryDatabase db) async {',
      'static Future<void> _schema(MoodiaryDatabase db, '
      '{bool allowMappedDays = false}) async {')
patch(file,
      "if (mapped.isNotEmpty) _fail('daily_not_in_graph_v1');",
      "if (mapped.isNotEmpty && !allowMappedDays) "
      "_fail('daily_not_in_graph_v1');")
patch(file,
      'static Future<Map<String,List<Map<String,Object?>>>> _snapshot(\n'
      '    MoodiaryDatabase db,\n'
      '  ) async {\n'
      '    await _schema(db);',
      'static Future<Map<String,List<Map<String,Object?>>>> _snapshot(\n'
      '    MoodiaryDatabase db, {bool allowMappedDays = false},\n'
      '  ) async {\n'
      '    await _schema(db, allowMappedDays: allowMappedDays);')
patch(file,
      '  /// Verification does not touch SQLite or modify the supplied source.\n'
      '  static void verify(String encoded) {',
      '''  /// INTERNAL: one component of the V2 day envelope, not a backup.
  /// V2 captures day rows in the SAME transaction and validates them.
  static Future<String> exportMonthPartForDayEnvelopeV2(MoodiaryDatabase db) =>
      db.transaction(() async {
        final tables = await _snapshot(db, allowMappedDays: true);
        _validate(tables);
        final body = _payload(tables);
        return jsonEncode({...body, 'sha256': _sha(body)});
      });

  /// Verification does not touch SQLite or modify the supplied source.
  static void verify(String encoded) {''')

patch('packages/feature_base/moodiary_data/lib/moodiary_data.dart',
      "export 'src/mod_day_map.dart';",
      "export 'src/mod_day_map.dart';\n"
      "export 'src/mod_month_graph_archive_v2.dart';")
patch('mobile/pubspec.yaml',
      'version: 2.9.2+112','version: 2.9.2+113')
print('W9.8.3 V2 graph and isolated recovery overlay staged; legacy gates unchanged')
