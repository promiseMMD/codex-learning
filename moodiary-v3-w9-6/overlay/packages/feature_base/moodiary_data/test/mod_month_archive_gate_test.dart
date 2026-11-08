import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moodiary_data/moodiary_data.dart';

void main() {
  late MoodiaryDatabase db;
  setUp(() async {
    db = MoodiaryDatabase.forTesting(NativeDatabase.memory());
    await db.customSelect('SELECT 1').get();
  });
  tearDown(() async { await db.close(); });

  test('empty v4 permits legacy archive', () async {
    await ModMonthArchiveGate.requireLegacyOnly(db);
  });

  test('a W9 month mapping forbids incomplete archive without mutating data', () async {
    await db.customStatement(
      'INSERT INTO mod_month_pages(topic_id,month_key,diary_id,created_ms) '
      'VALUES(?,?,NULL,?)', ['test-topic', '2026-11', 10]);
    await expectLater(ModMonthArchiveGate.requireLegacyOnly(db),
      throwsA(isA<ModMonthArchiveBlocked>().having(
        (e) => e.code, 'code', 'structured_data_not_covered')));
    final row = await db.customSelect(
      'SELECT COUNT(*) AS n FROM mod_month_pages').getSingle();
    expect(row.read<int>('n'), 1);
  });

  test('missing v4 schema fails closed', () async {
    await db.customStatement('DROP TABLE mod_month_ops');
    await expectLater(ModMonthArchiveGate.requireLegacyOnly(db),
      throwsA(isA<ModMonthArchiveBlocked>().having(
        (e) => e.code, 'code', 'structured_schema_incomplete')));
  });

  test('failed preflight is repeatable and never inserts operation rows', () async {
    await db.customStatement(
      'INSERT INTO mod_month_pages(topic_id,month_key,diary_id,created_ms) '
      'VALUES(?,?,NULL,?)', ['test-topic', '2026-11', 10]);
    for (var i = 0; i < 2; i++) {
      await expectLater(ModMonthArchiveGate.requireLegacyOnly(db),
          throwsA(isA<ModMonthArchiveBlocked>()));
    }
    expect(await db.customSelect('SELECT * FROM mod_month_ops').get(), isEmpty);
  });
}
