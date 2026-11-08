import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moodiary_data/moodiary_data.dart';

const topic = 'aac26e25-4a1d-4b4c-b256-9b0c347d36e2';
const entry = 'entry-block-0001';
const summary = 'summary-block-0001';
const root = 'revision-root-0001';
const moved = 'revision-moved-0001';
const summaryRevision = 'revision-summary-0001';

String document(String text) => jsonEncode({
  'type': 'doc', 'attrs': {'v': 2},
  'content': [
    {'type':'paragraph','content':[{'type':'text','text':text}]}
  ],
});

String hash(Object item) =>
    sha256.convert(utf8.encode(jsonEncode(item))).toString();

Future<void> seed(MoodiaryDatabase db) async {
  const november = '2026-11', december = '2026-12';
  const novDay = '2026-11-07', decDay = '2026-12-01';
  final initial = document('原始记录，跨月前');
  final deleted = document('跨月后删除，但保留内容');
  final report = document('月度总结不属于每日正文');

  for (final month in [november,december]) {
    await db.customStatement(
      'INSERT INTO mod_month_pages(topic_id,month_key,diary_id,created_ms)'
      ' VALUES(?,?,NULL,?)',
      [topic,month,1794038400000],
    );
  }
  await db.customStatement(
    'INSERT INTO mod_month_blocks(block_id,topic_id,month_key,kind,created_ms)'
    ' VALUES(?,?,?,?,?)',
    [entry,topic,december,'entry',1794038400100],
  );
  await db.customStatement(
    'INSERT INTO mod_month_blocks(block_id,topic_id,month_key,kind,created_ms)'
    ' VALUES(?,?,?,?,?)',
    [summary,topic,november,'summary',1794038400200],
  );
  // Revision UUID ordering is intentionally different from event time.
  // Original root and later tombstone both survive in the same graph.
  Future<void> addRevision({
    required String revision, required String blockId, String? parent,
    required String month, String? day, required int event,
    required String body, bool deleted = false,
  }) async {
    await db.customStatement(
      'INSERT INTO mod_month_revisions'
      '(revision_id,block_id,parent_revision_id,month_key,day_key,'
      'occurred_at_ms,body_json,deleted,edited_at_ms)'
      ' VALUES(?,?,?,?,?,?,?,?,?)',
      [revision,blockId,parent,month,day,event,body,deleted?1:0,event+100],
    );
    final operation = 'operation-' + revision;
    final kind = blockId == entry ? 'entry' : 'summary';
    await db.customStatement(
      'INSERT INTO mod_month_ops'
      '(operation_id,payload_sha256,block_id,revision_id,applied_at_ms)'
      ' VALUES(?,?,?,?,?)',
      [operation,hash([blockId,revision,topic,month,kind,parent,day,event,
        body,deleted]),blockId,revision,event+100],
    );
  }
  await addRevision(revision:root,blockId:entry,month:november,
      day:novDay,event:1794038400123,body:initial);
  await addRevision(revision:moved,blockId:entry,parent:root,month:december,
      day:decDay,event:1794038400456,body:deleted,deleted:true);
  await addRevision(revision:summaryRevision,blockId:summary,month:november,
      day:null,event:1794038400700,body:report);
  for (final (block,revision) in [
    (entry,moved),(summary,summaryRevision),
  ]) {
    await db.customStatement(
      'INSERT INTO mod_month_heads(block_id,revision_id) VALUES(?,?)',
      [block,revision],
    );
  }
}

void main() {
  late MoodiaryDatabase original;
  late MoodiaryDatabase isolated;

  setUp(() async {
    original = MoodiaryDatabase.forTesting(NativeDatabase.memory());
    isolated = MoodiaryDatabase.forTesting(NativeDatabase.memory());
    await original.customSelect('SELECT 1').get();
    await isolated.customSelect('SELECT 1').get();
  });
  tearDown(() async {
    await original.close();
    await isolated.close();
  });

  test('lossless two-month full graph round trip, stable IDs, tombstones and summary', () async {
    await seed(original);
    final exported = await ModMonthGraphArchiveV1.exportGraph(original);
    ModMonthGraphArchiveV1.verify(exported);
    await ModMonthGraphArchiveV1.restoreIntoIsolatedEmptyDatabaseForTest(
      isolated,exported);
    final restored = await ModMonthGraphArchiveV1.exportGraph(isolated);
    expect(restored, exported, reason:'all original values and revisions retained');
    final tables = (jsonDecode(restored) as Map<String,dynamic>)['tables']
        as Map<String,dynamic>;
    expect((tables['mod_month_pages'] as List).length, 2);
    expect((tables['mod_month_revisions'] as List).length, 3);
    expect((tables['mod_month_heads'] as List).length, 2);
    expect((tables['mod_month_ops'] as List).length, 3);
    expect((tables['mod_month_revisions'] as List).any(
      (r) => r['revision_id']==moved && r['deleted']==1),isTrue);
    expect((tables['mod_month_blocks'] as List).any(
      (r) => r['kind']=='summary'),isTrue);
  });

  test('export is byte-deterministic and never writes to its source', () async {
    await seed(original);
    final first = await ModMonthGraphArchiveV1.exportGraph(original);
    final again = await ModMonthGraphArchiveV1.exportGraph(original);
    expect(again,first);
    expect((await original.customSelect(
      'SELECT COUNT(*) AS n FROM mod_month_revisions'
    ).getSingle()).read<int>('n'),3);
  });

  test('corrupted body checksum is rejected with zero target writes', () async {
    await seed(original);
    final json = jsonDecode(await ModMonthGraphArchiveV1.exportGraph(original))
        as Map<String,dynamic>;
    final table = json['tables'] as Map<String,dynamic>;
    final row = (table['mod_month_revisions'] as List).first
        as Map<String,dynamic>;
    row['body_json'] = document('恶意篡改');
    final corrupt = jsonEncode(json);
    expect(() => ModMonthGraphArchiveV1.verify(corrupt),
      throwsA(isA<ModGraphArchiveException>().having(
        (e)=>e.code,'code','checksum_mismatch')));
    await expectLater(
      ModMonthGraphArchiveV1.restoreIntoIsolatedEmptyDatabaseForTest(
        isolated,corrupt), throwsA(isA<ModGraphArchiveException>()));
    expect((await isolated.customSelect(
      'SELECT COUNT(*) AS n FROM mod_month_blocks'
    ).getSingle()).read<int>('n'),0);
  });

  test('rehashed forged foreign head is rejected, still no writes', () async {
    await seed(original);
    final json = jsonDecode(await ModMonthGraphArchiveV1.exportGraph(original))
        as Map<String,dynamic>;
    final tables = json['tables'] as Map<String,dynamic>;
    (tables['mod_month_heads'] as List).first['revision_id']='missing-revision';
    json['sha256']=hash({
      'format':json['format'],'version':json['version'],'tables':tables
    });
    final forged = jsonEncode(json);
    expect(() => ModMonthGraphArchiveV1.verify(forged),
      throwsA(isA<ModGraphArchiveException>().having(
        (e)=>e.code,'code','bad_head')));
    await expectLater(
      ModMonthGraphArchiveV1.restoreIntoIsolatedEmptyDatabaseForTest(
        isolated,forged),throwsA(isA<ModGraphArchiveException>()));
    expect((await isolated.customSelect(
      'SELECT COUNT(*) AS n FROM mod_month_ops'
    ).getSingle()).read<int>('n'),0);
  });

  test('restore is never a merge and refuses a nonempty destination', () async {
    await seed(original);
    await seed(isolated);
    final input = await ModMonthGraphArchiveV1.exportGraph(original);
    await expectLater(
      ModMonthGraphArchiveV1.restoreIntoIsolatedEmptyDatabaseForTest(
        isolated,input),
      throwsA(isA<ModGraphArchiveException>().having(
        (e)=>e.code,'code','nonempty_target')),
    );
    expect(await ModMonthGraphArchiveV1.exportGraph(isolated),input);
  });

  test('second identical restore is denied rather than silently overwriting', () async {
    await seed(original);
    final input = await ModMonthGraphArchiveV1.exportGraph(original);
    await ModMonthGraphArchiveV1.restoreIntoIsolatedEmptyDatabaseForTest(
      isolated,input);
    await expectLater(
      ModMonthGraphArchiveV1.restoreIntoIsolatedEmptyDatabaseForTest(
        isolated,input),throwsA(isA<ModGraphArchiveException>()));
    expect(await ModMonthGraphArchiveV1.exportGraph(isolated),input);
  });

  test('missing schema blocks export, without schema auto-repair', () async {
    await original.customStatement('DROP TABLE mod_month_ops');
    await expectLater(ModMonthGraphArchiveV1.exportGraph(original),
      throwsA(isA<ModGraphArchiveException>().having(
        (e)=>e.code,'code','schema_not_exact')));
  });
}
