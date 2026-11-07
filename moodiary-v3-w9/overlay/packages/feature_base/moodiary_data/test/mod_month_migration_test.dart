import 'dart:convert';

import 'package:drift/drift.dart' hide isNull;
import 'package:drift_dev/api/migrations_native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moodiary_data/moodiary_data.dart';
import 'package:sqlite3_simple/sqlite3_simple.dart';

import 'drift/moodiary/generated/schema.dart';
import 'drift/moodiary/generated/schema_v2.dart' as v2;
import 'drift/moodiary/generated/schema_v3.dart' as v3;

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  late SchemaVerifier verifier;

  setUpAll(() {
    loadSimpleExtension();
    installJiebaDict();
    verifier = SchemaVerifier(GeneratedHelper());
  });

  test('W9 upgrade v3 to v4 preserves normal diary exact content and metadata', () async {
    final schema = await verifier.schemaAt(3);
    final old = v3.DatabaseAtV3(schema.newConnection());
    const id = '1c042158-916c-458e-8921-63e8529f6eb0';
    final content = jsonEncode({
      'type': 'doc', 'attrs': {'v': 2},
      'content': [
        {'type': 'paragraph', 'content': [
          {'type': 'text', 'text': '既有的日记不能丢失'},
        ]},
      ],
    });
    await old.into(old.diaries).insert(v3.DiariesCompanion.insert(
      id: id, title: '升级前的旧日记', content: content,
      contentText: '既有的日记不能丢失',
      time: 1730950123456, lastModified: 1730950999888,
      show: 1, type: 'tiptap',
    ));
    await old.close();

    final upgraded = MoodiaryDatabase.forTesting(schema.newConnection());
    final uv = await upgraded.customSelect('PRAGMA user_version').getSingle();
    expect(uv.read<int>('user_version'), 4);
    final diary = await upgraded.customSelect(
      'SELECT title,content,content_text,time,last_modified,show,type '
      'FROM diaries WHERE id = ?',
      variables: [Variable.withString(id)],
    ).getSingle();
    expect(diary.read<String>('title'), '升级前的旧日记');
    expect(diary.read<String>('content'), content);
    expect(diary.read<String>('content_text'), '既有的日记不能丢失');
    expect(diary.read<int>('time'), 1730950123456);
    expect(diary.read<int>('last_modified'), 1730950999888);
    expect(diary.read<int>('show'), 1);
    expect(diary.read<String>('type'), 'tiptap');
    final objects = await upgraded.customSelect(
      "SELECT name FROM sqlite_master WHERE type='table' AND name LIKE 'mod_month_%'",
    ).get();
    expect(objects.map((r) => r.read<String>('name')).toSet(), {
      'mod_month_pages','mod_month_blocks','mod_month_revisions',
      'mod_month_heads','mod_month_ops'
    });
    final untouched = await upgraded.customSelect(
      'SELECT COUNT(*) AS n FROM mod_month_blocks'
    ).getSingle();
    expect(untouched.read<int>('n'), 0);
    await upgraded.close();
  });

  test('W9 upgrade from v2 applies original migration before additive v4', () async {
    final schema = await verifier.schemaAt(2);
    final old = v2.DatabaseAtV2(schema.newConnection());
    await old.into(old.diaries).insert(v2.DiariesCompanion.insert(
      id: 'old-upgrade-row',
      title: '旧版苹果日记',
      content: '',
      contentText: '苹果和工作记录',
      time: 1760000000000,
      lastModified: 1760000000020,
      show: 1,
      mood: 'neutral',
      type: 'tiptap',
    ));
    await old.close();

    final upgraded = MoodiaryDatabase.forTesting(schema.newConnection());
    final uv = await upgraded.customSelect('PRAGMA user_version').getSingle();
    expect(uv.read<int>('user_version'), 4);
    final legacy = await upgraded.customSelect(
      'SELECT title,content_text,mood_level FROM diaries WHERE id = ?',
      variables: [const Variable.withString('old-upgrade-row')],
    ).getSingle();
    expect(legacy.read<String>('title'), '旧版苹果日记');
    expect(legacy.read<String>('content_text'), '苹果和工作记录');
    expect(legacy.readNullable<int>('mood_level'), isNull);
    final v4 = await upgraded.customSelect(
      'SELECT COUNT(*) AS n FROM mod_month_pages',
    ).getSingle();
    expect(v4.read<int>('n'), 0);
    await upgraded.close();
  });
}
