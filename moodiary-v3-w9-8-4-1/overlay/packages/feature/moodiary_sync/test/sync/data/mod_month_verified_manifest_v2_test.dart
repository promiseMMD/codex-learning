import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moodiary_data/moodiary_data.dart';
import 'package:moodiary_models/moodiary_models.dart';
import 'package:moodiary_sync/src/data/model/manifest.dart';
import 'package:moodiary_sync/src/data/mod_month_verified_manifest_v1.dart';
import 'package:moodiary_sync/src/data/mod_month_verified_manifest_v2.dart';

import '../sync_test_harness.dart';

const topic='aac26e25-4a1d-4b4c-b256-9b0c347d36e2';
const block='block-00000001';
const revision='revision-00000001';
const day='2026-11-07';
Uint8List bytes(String text)=>Uint8List.fromList(utf8.encode(text));
String hash(Object value)=>sha256.convert(utf8.encode(jsonEncode(value))).toString();
bool isTopic(Diary diary)=>diary.tags.contains('test-long-topic');

Future<void> seed(MoodiaryDatabase db) async {
  final doc=jsonEncode({
    'type':'doc','attrs':{'v':2},
    'content':[{'type':'image','attrs':{'src':'history.png'}}],
  });
  await db.customStatement(
    'INSERT INTO mod_month_pages'
    '(topic_id,month_key,diary_id,created_ms) VALUES(?,?,NULL,?)',
    [topic,'2026-11',1]);
  await db.customStatement(
    'INSERT INTO mod_month_blocks'
    '(block_id,topic_id,month_key,kind,created_ms) VALUES(?,?,?,?,?)',
    [block,topic,'2026-11','entry',2]);
  await db.customStatement(
    'INSERT INTO mod_month_revisions'
    '(revision_id,block_id,parent_revision_id,month_key,day_key,'
    'occurred_at_ms,body_json,deleted,edited_at_ms)'
    ' VALUES(?,?,NULL,?,?,?,?,?,?)',
    [revision,block,'2026-11',day,3,doc,0,4]);
  await db.customStatement(
    'INSERT INTO mod_month_heads(block_id,revision_id) VALUES(?,?)',
    [block,revision]);
  await db.customStatement(
    'INSERT INTO mod_month_ops'
    '(operation_id,payload_sha256,block_id,revision_id,applied_at_ms)'
    ' VALUES(?,?,?,?,?)',
    ['operation-0001',
     hash([block,revision,topic,'2026-11','entry',null,day,3,doc,false]),
     block,revision,4]);
  await db.customStatement(
    'INSERT INTO mod_day_pages'
    '(topic_id,day_key,diary_id,visible_local,created_ms)'
    ' VALUES(?,?,NULL,0,?)',
    [topic,day,5]);
}

Future<Map<String,Uint8List>> payload(MoodiaryDatabase db) async {
  final d=buildDiary(id:topic,title:'正常的长期主题',
    images:['native.png']).copyWith(tags:['test-long-topic']);
  final graph=await ModMonthGraphArchiveV2.exportGraph(db);
  final dayBindings=await db.customSelect(
    'SELECT diary_id FROM mod_day_pages WHERE diary_id IS NOT NULL').get();
  final boundIds={
    for(final row in dayBindings) row.read<String>('diary_id'),
  };
  final boundDiaries={
    for(final id in boundIds)
      id:buildDiary(id:id,title:'日期映射原生日记',modifiedMs:111),
  };
  final manifest=SyncManifest(
    version:SyncManifest.currentVersion,updatedAtMs:120,
    entries:{
      'd:$topic':const ManifestEntry(
        timeMs:110,media:['image/native.png']),
      for(final id in boundIds)
        'd:$id':const ManifestEntry(timeMs:111),
      'd:deleted-00000001':const ManifestEntry(timeMs:90,deleted:true),
    },
  );
  return {
    'manifest.json':bytes(jsonEncode(manifest.toJson())),
    'diary/$topic.json':bytes(jsonEncode(d.toJson())),
    for(final e in boundDiaries.entries)
      'diary/${e.key}.json':bytes(jsonEncode(e.value.toJson())),
    'media/image/native.png':Uint8List.fromList([1,2,3]),
    'media/image/history.png':Uint8List.fromList([4,5,6]),
    ModMonthVerifiedManifestV2.graphPath:bytes(graph),
  };
}

void main(){
  late MoodiaryDatabase db;
  setUp(() async {
    db=MoodiaryDatabase.forTesting(NativeDatabase.memory());
    await db.customSelect('SELECT 1').get();
    await seed(db);
  });
  tearDown(() async => db.close());

  test('V1 cannot archive day map; V2 closes native, historic media and day map', () async {
    final files=await payload(db);
    await expectLater(ModMonthGraphArchiveV1.exportGraph(db),
      throwsA(isA<ModGraphArchiveException>().having(
        (e)=>e.code,'code','daily_not_in_graph_v1')));
    final sealed=ModMonthVerifiedManifestV2.seal(
      staged:files,isTopic:isTopic);
    expect(ModMonthVerifiedManifestV2.seal(
      staged:files,isTopic:isTopic),sealed);
    ModMonthVerifiedManifestV2.verify(
      manifest:sealed,staged:files,isTopic:isTopic);
    final record=jsonDecode(sealed) as Map<String,dynamic>;
    expect(record['version'],2);
    expect(record['scope'],'native-structured-and-media');
    expect(record['topics'],[topic]);
    final paths=(record['files'] as List<dynamic>)
      .map((e)=>e['path'] as String).toList();
    expect(paths,orderedEquals([...paths]..sort()));
    expect(paths,containsAll([
      'manifest.json','diary/$topic.json','media/image/native.png',
      'media/image/history.png',ModMonthVerifiedManifestV2.graphPath,
    ]));
    expect(paths, isNot(contains(ModMonthVerifiedManifestV1.graphPath)));
    final envelope=jsonDecode(utf8.decode(
      files[ModMonthVerifiedManifestV2.graphPath]!)) as Map<String,dynamic>;
    expect((envelope['dayPages'] as List<dynamic>).single['visible_local'],0);
  });

  test('day Diary binding must be present in the same native archive',() async {
    await db.customStatement(
      'INSERT INTO diaries'
      '(id,title,content,content_text,time,last_modified,show,type)'
      ' VALUES(?,?,?,?,?,?,?,?)',
      ['native-day-0001','日期映射原生日记','原始内容','原始内容',1,111,1,'tiptap']);
    await db.customStatement(
      'UPDATE mod_day_pages SET diary_id=? WHERE topic_id=? AND day_key=?',
      ['native-day-0001',topic,day]);
    final files=await payload(db);
    final sealed=ModMonthVerifiedManifestV2.seal(
      staged:files,isTopic:isTopic);
    ModMonthVerifiedManifestV2.verify(
      manifest:sealed,staged:files,isTopic:isTopic);
    final native=SyncManifest.fromJson(
      jsonDecode(utf8.decode(files['manifest.json']!)) as Map<String,dynamic>);
    native.entries.remove(SyncKeys.diary('native-day-0001'));
    files['manifest.json']=bytes(jsonEncode(native.toJson()));
    expect(()=>ModMonthVerifiedManifestV2.seal(
      staged:files,isTopic:isTopic),
      throwsA(isA<ModBundleInvalid>().having(
        (e)=>e.code,'code','bound_day_diary_not_backed_up')));
  });

  test('missing historical media aborts even if native media is complete',() async {
    final files=await payload(db);
    files.remove('media/image/history.png');
    expect(()=>ModMonthVerifiedManifestV2.seal(
      staged:files,isTopic:isTopic),
      throwsA(isA<ModBundleInvalid>().having(
        (e)=>e.code,'code','missing_media_bytes')));
  });

  test('missing native topic diary and native media both abort',() async {
    final files=await payload(db);
    files.remove('diary/$topic.json');
    expect(()=>ModMonthVerifiedManifestV2.seal(
      staged:files,isTopic:isTopic),
      throwsA(isA<ModBundleInvalid>().having(
        (e)=>e.code,'code','missing_native_entity')));
    final another=await payload(db);
    another.remove('media/image/native.png');
    expect(()=>ModMonthVerifiedManifestV2.seal(
      staged:another,isTopic:isTopic),
      throwsA(isA<ModBundleInvalid>().having(
        (e)=>e.code,'code','missing_media_bytes')));
  });

  test('tampered payload and forged V2 day graph both fail closed',() async {
    final files=await payload(db);
    final sealed=ModMonthVerifiedManifestV2.seal(
      staged:files,isTopic:isTopic);
    files['media/image/native.png']=Uint8List.fromList([3,2,1]);
    expect(()=>ModMonthVerifiedManifestV2.verify(
      manifest:sealed,staged:files,isTopic:isTopic),
      throwsA(isA<ModBundleInvalid>().having(
        (e)=>e.code,'code','v2_bundle_integrity_mismatch')));
    final another=await payload(db);
    final graph=jsonDecode(utf8.decode(
      another[ModMonthVerifiedManifestV2.graphPath]!))
      as Map<String,dynamic>;
    (graph['dayPages'] as List<dynamic>).single['visible_local']=1;
    another[ModMonthVerifiedManifestV2.graphPath]=bytes(jsonEncode(graph));
    expect(()=>ModMonthVerifiedManifestV2.seal(
      staged:another,isTopic:isTopic),
      throwsA(isA<ModBundleInvalid>().having(
        (e)=>e.code,'code','invalid_v2_graph')));
  });

  test('V1 graph replacement, path traversal and stray diary are refused',() async {
    final files=await payload(db);
    files[ModMonthVerifiedManifestV1.graphPath]=bytes('forged-v1');
    expect(()=>ModMonthVerifiedManifestV2.seal(
      staged:files,isTopic:isTopic),
      throwsA(isA<ModBundleInvalid>().having(
        (e)=>e.code,'code','unsafe_v2_payload_path')));
    files.remove(ModMonthVerifiedManifestV1.graphPath);
    files['media/image/../escape.png']=bytes('bad');
    expect(()=>ModMonthVerifiedManifestV2.seal(
      staged:files,isTopic:isTopic),
      throwsA(isA<ModBundleInvalid>().having(
        (e)=>e.code,'code','unsafe_v2_payload_path')));
    files.remove('media/image/../escape.png');
    files['diary/stray0001.json']=bytes('{"id":"stray0001"}');
    expect(()=>ModMonthVerifiedManifestV2.seal(
      staged:files,isTopic:isTopic),
      throwsA(isA<ModBundleInvalid>().having(
        (e)=>e.code,'code','orphan_entity_payload')));
  });

  test('manifest bytes and source file map stay immutable during seal',() async {
    final files=await payload(db);
    final before={
      for(final e in files.entries)e.key:List<int>.of(e.value),
    };
    final sealed=ModMonthVerifiedManifestV2.seal(
      staged:files,isTopic:isTopic);
    final corrupt=jsonDecode(sealed) as Map<String,dynamic>;
    corrupt['scope']='downgraded';
    expect(()=>ModMonthVerifiedManifestV2.verify(
      manifest:jsonEncode(corrupt),staged:files,isTopic:isTopic),
      throwsA(isA<ModBundleInvalid>().having(
        (e)=>e.code,'code','invalid_v2_manifest')));
    for(final e in files.entries) {
      expect(e.value,orderedEquals(before[e.key]!));
    }
  });

  test('verified receipts permit large streamed media without Dart allocation',
      () async {
    final staged=await payload(db);
    // Separate media is not referenced by the graph and is permitted by
    // the conservative V1 full-closure contract as an explicit extra asset.
    final receipts={
      for(final e in staged.entries)
        e.key:(size:e.value.lengthInBytes,sha256:sha256.convert(e.value).toString()),
      'media/video/large.mp4':(size:257*1024*1024,sha256:'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'),
    };
    final metadata={
      for(final e in staged.entries)
        if(!e.key.startsWith('media/')) e.key:e.value,
    };
    final seal=ModMonthVerifiedManifestV2.sealWithReceipts(
      receipts:receipts,metadata:metadata,isTopic:isTopic);
    ModMonthVerifiedManifestV2.verifyWithReceipts(
      manifest:seal,receipts:receipts,metadata:metadata,isTopic:isTopic);
    expect((jsonDecode(seal) as Map<String,dynamic>)['files'],
      hasLength(staged.length+1));
  });
}
