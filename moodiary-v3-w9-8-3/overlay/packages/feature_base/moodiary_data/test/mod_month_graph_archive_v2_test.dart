import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moodiary_data/moodiary_data.dart';

const topic='aac26e25-4a1d-4b4c-b256-9b0c347d36e2';
const nov='2026-11';
const dec='2026-12';
const novDay='2026-11-07';
const decDay='2026-12-01';
const entry='block-moved-0001';
const summary='block-summary-001';
const revA='revision-root-001';
const revB='revision-moved-01';
const revS='revision-summary-1';

String document(String text)=>jsonEncode({
  'type':'doc','attrs':{'v':2},
  'content':[{'type':'paragraph','content':[{'type':'text','text':text}]}],
});
String sha(Object value)=>sha256.convert(utf8.encode(jsonEncode(value))).toString();

Future<void> seed(MoodiaryDatabase db) async {
  for(final key in [nov,dec]){
    await db.customStatement(
      'INSERT INTO mod_month_pages'
      '(topic_id,month_key,diary_id,created_ms) VALUES(?,?,NULL,?)',
      [topic,key,1000]);
  }
  await db.customStatement(
    'INSERT INTO mod_month_blocks'
    '(block_id,topic_id,month_key,kind,created_ms) VALUES(?,?,?,?,?)',
    [entry,topic,dec,'entry',1001]);
  await db.customStatement(
    'INSERT INTO mod_month_blocks'
    '(block_id,topic_id,month_key,kind,created_ms) VALUES(?,?,?,?,?)',
    [summary,topic,nov,'summary',1002]);

  Future<void> revision({
    required String id,required String block,String? parent,
    required String month,String? day,required int at,required String body,
    bool deleted=false,
  }) async {
    await db.customStatement(
      'INSERT INTO mod_month_revisions'
      '(revision_id,block_id,parent_revision_id,month_key,day_key,'
      'occurred_at_ms,body_json,deleted,edited_at_ms)'
      ' VALUES(?,?,?,?,?,?,?,?,?)',
      [id,block,parent,month,day,at,body,deleted?1:0,at+100]);
    final kind=block==entry?'entry':'summary';
    await db.customStatement(
      'INSERT INTO mod_month_ops'
      '(operation_id,payload_sha256,block_id,revision_id,applied_at_ms)'
      ' VALUES(?,?,?,?,?)',
      ['operation-'+id,
       sha([block,id,topic,month,kind,parent,day,at,body,deleted]),
       block,id,at+100]);
  }
  await revision(id:revA,block:entry,month:nov,day:novDay,
      at:1100,body:document('原始记录含图片引用'));
  await revision(id:revB,block:entry,parent:revA,month:dec,
      day:decDay,at:1300,body:document('跨月已删除，但修订历史保留'),
      deleted:true);
  await revision(id:revS,block:summary,month:nov,at:1400,
      body:document('月总结'));
  for(final pair in [(entry,revB),(summary,revS)]){
    await db.customStatement(
      'INSERT INTO mod_month_heads(block_id,revision_id) VALUES(?,?)',
      [pair.$1,pair.$2]);
  }
  // Both mappings can outlive a move, and one is explicitly hidden locally.
  for(final pair in [(novDay,0),(decDay,1)]){
    await db.customStatement(
      'INSERT INTO mod_day_pages'
      '(topic_id,day_key,diary_id,visible_local,created_ms)'
      ' VALUES(?,?,NULL,?,?)',
      [topic,pair.$1,pair.$2,1500]);
  }
}

String forge(Map<String,dynamic> archive) {
  final body={
    'format':archive['format'],
    'version':archive['version'],
    'scope':archive['scope'],
    'monthGraph':archive['monthGraph'],
    'dayPages':archive['dayPages'],
  };
  return jsonEncode({...body,'sha256':sha(body)});
}

Future<int> count(MoodiaryDatabase db,String name) async =>
    (await db.customSelect('SELECT COUNT(*) AS n FROM '+name)
      .getSingle()).read<int>('n');

void main() {
  late MoodiaryDatabase source;
  late MoodiaryDatabase empty;

  setUp(() async {
    source=MoodiaryDatabase.forTesting(NativeDatabase.memory());
    empty=MoodiaryDatabase.forTesting(NativeDatabase.memory());
    await source.customSelect('SELECT 1').get();
    await empty.customSelect('SELECT 1').get();
  });
  tearDown(() async {
    await source.close();
    await empty.close();
  });

  test('V1 must fail closed; V2 keeps all dates, flags, tombstones and revisions', () async {
    await seed(source);
    await expectLater(ModMonthGraphArchiveV1.exportGraph(source),
      throwsA(isA<ModGraphArchiveException>().having(
        (e)=>e.code,'code','daily_not_in_graph_v1')));
    final before=await ModMonthGraphArchiveV2.exportGraph(source);
    ModMonthGraphArchiveV2.verify(before);
    expect(await ModMonthGraphArchiveV2.exportGraph(source),before);
    final json=jsonDecode(before) as Map<String,dynamic>;
    final days=json['dayPages'] as List<dynamic>;
    expect(days.map((r)=>r['day_key']).toList(),[novDay,decDay],
      reason:'canonical day ascending ordering');
    expect(days.map((r)=>r['visible_local']).toList(),[0,1]);
    final graph=(json['monthGraph'] as Map<String,dynamic>)['tables']
      as Map<String,dynamic>;
    expect((graph['mod_month_revisions'] as List<dynamic>).length,3);
    expect((graph['mod_month_heads'] as List<dynamic>).length,2);
    expect((graph['mod_month_ops'] as List<dynamic>).length,3);
    expect((graph['mod_month_revisions'] as List<dynamic>).any(
      (v)=>v['deleted']==1),true);
    expect(await count(source,'diaries'),0);
    expect(await count(source,'mod_day_pages'),2);
    await ModMonthGraphArchiveV2.restoreIntoIsolatedEmptyDatabaseForTest(
      empty,before);
    final after=await ModMonthGraphArchiveV2.exportGraph(empty);
    expect(after,before,reason:'lossless V2 isolated round trip');
    expect(await count(empty,'diaries'),0);
  });

  test('one-byte tamper fails checksum before ANY isolated target writes', () async {
    await seed(source);
    final first=jsonDecode(await ModMonthGraphArchiveV2.exportGraph(source))
      as Map<String,dynamic>;
    (first['dayPages'] as List<dynamic>).first['visible_local']=1;
    final altered=jsonEncode(first);
    expect(()=>ModMonthGraphArchiveV2.verify(altered),
      throwsA(isA<ModGraphV2Exception>().having(
        (e)=>e.code,'code','checksum_mismatch')));
    await expectLater(
      ModMonthGraphArchiveV2.restoreIntoIsolatedEmptyDatabaseForTest(
        empty,altered),throwsA(isA<ModGraphV2Exception>()));
    expect(await count(empty,'mod_day_pages'),0);
    expect(await count(empty,'mod_month_revisions'),0);
  });

  test('rehashed invalid visible flag and orphan date are rejected', () async {
    await seed(source);
    final first=jsonDecode(await ModMonthGraphArchiveV2.exportGraph(source))
        as Map<String,dynamic>;
    (first['dayPages'] as List<dynamic>).first['visible_local']=2;
    expect(()=>ModMonthGraphArchiveV2.verify(forge(first)),
      throwsA(isA<ModGraphV2Exception>().having(
        (e)=>e.code,'code','invalid_day_metadata')));
    (first['dayPages'] as List<dynamic>).first['visible_local']=0;
    (first['dayPages'] as List<dynamic>).last['day_key']='2026-12-02';
    expect(()=>ModMonthGraphArchiveV2.verify(forge(first)),
      throwsA(isA<ModGraphV2Exception>().having(
        (e)=>e.code,'code','orphan_day_mapping')));
    expect(await count(empty,'mod_month_ops'),0);
  });

  test('duplicate mapping and forged internal month graph are rejected', () async {
    await seed(source);
    final origin=jsonDecode(await ModMonthGraphArchiveV2.exportGraph(source))
      as Map<String,dynamic>;
    (origin['dayPages'] as List<dynamic>).add(
      Map<String,dynamic>.from((origin['dayPages'] as List<dynamic>).last));
    expect(()=>ModMonthGraphArchiveV2.verify(forge(origin)),
      throwsA(isA<ModGraphV2Exception>().having(
        (e)=>e.code,'code','duplicate_day_mapping')));
    (origin['dayPages'] as List<dynamic>).removeLast();
    final graph=origin['monthGraph'] as Map<String,dynamic>;
    final tables=graph['tables'] as Map<String,dynamic>;
    (tables['mod_month_revisions'] as List<dynamic>).first['body_json']
      =document('forged and not covered by original graph checksum');
    expect(()=>ModMonthGraphArchiveV2.verify(forge(origin)),
      throwsA(isA<ModGraphV2Exception>().having(
        (e)=>e.code,'code','invalid_month_graph')));
  });

  test('existing target and second restore are refused without modifying bytes', () async {
    await seed(source);
    final archive=await ModMonthGraphArchiveV2.exportGraph(source);
    await seed(empty);
    await expectLater(
      ModMonthGraphArchiveV2.restoreIntoIsolatedEmptyDatabaseForTest(
        empty,archive),
      throwsA(isA<ModGraphV2Exception>().having(
        (e)=>e.code,'code','nonempty_day_target')));
    expect(await ModMonthGraphArchiveV2.exportGraph(empty),archive);
    await empty.close();
    empty=MoodiaryDatabase.forTesting(NativeDatabase.memory());
    await empty.customSelect('SELECT 1').get();
    await ModMonthGraphArchiveV2.restoreIntoIsolatedEmptyDatabaseForTest(
      empty,archive);
    await expectLater(
      ModMonthGraphArchiveV2.restoreIntoIsolatedEmptyDatabaseForTest(
        empty,archive),throwsA(isA<ModGraphV2Exception>()));
    expect(await ModMonthGraphArchiveV2.exportGraph(empty),archive);
  });

  test('bound native Diaries export and production graph restore are lossless', () async {
    await seed(source);
    Future<void> addDiary(MoodiaryDatabase db,String id) => db.customStatement(
      'INSERT INTO diaries'
      '(id,title,content,content_text,time,last_modified,show,type)'
      ' VALUES(?,?,?,?,?,?,?,?)',
      [id,'untouched native diary','original bytes','original bytes',
       1,2,1,'tiptap']);
    await addDiary(source,topic);
    await addDiary(source,'native-month-0001');
    await addDiary(source,'native-day-0001');
    await source.customStatement(
      'UPDATE mod_month_pages SET diary_id=?'
      ' WHERE topic_id=? AND month_key=?',
      ['native-month-0001',topic,nov]);
    await source.customStatement(
      'UPDATE mod_day_pages SET diary_id=? WHERE topic_id=? AND day_key=?',
      ['native-day-0001',topic,novDay]);

    final archive=await ModMonthGraphArchiveV2.exportGraph(source);
    ModMonthGraphArchiveV2.verify(archive);
    final json=jsonDecode(archive) as Map<String,dynamic>;
    final tables=(json['monthGraph'] as Map<String,dynamic>)['tables']
      as Map<String,dynamic>;
    expect((tables['mod_month_pages'] as List<dynamic>)
      .firstWhere((r)=>r['month_key']==nov)['diary_id'],'native-month-0001');
    expect((json['dayPages'] as List<dynamic>)
      .firstWhere((r)=>r['day_key']==novDay)['diary_id'],'native-day-0001');

    await addDiary(empty,topic);
    await expectLater(
      ModMonthGraphArchiveV2.restoreIntoEmptyDatabase(empty,archive),
      throwsA(isA<ModGraphV2Exception>().having(
        (e)=>e.code,'code','missing_native_diary_binding')));
    expect(await count(empty,'mod_month_pages'),0);
    expect(await count(empty,'mod_day_pages'),0);

    await addDiary(empty,'native-month-0001');
    await addDiary(empty,'native-day-0001');
    await ModMonthGraphArchiveV2.restoreIntoEmptyDatabase(empty,archive);
    expect(await ModMonthGraphArchiveV2.exportGraph(empty),archive);
    // A retry of the exact same graph is idempotent; a different graph is not.
    await ModMonthGraphArchiveV2.restoreIntoEmptyDatabase(empty,archive);
    final unchanged=await source.customSelect('SELECT content FROM diaries').get();
    expect(unchanged.length,3);
    expect(unchanged.every((r)=>r.read<String>('content')=='original bytes'),true);
  });
}
