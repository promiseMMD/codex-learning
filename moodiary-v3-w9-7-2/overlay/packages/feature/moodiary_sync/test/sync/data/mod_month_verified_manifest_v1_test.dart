import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moodiary_data/moodiary_data.dart';
import 'package:moodiary_models/moodiary_models.dart';
import 'package:moodiary_sync/src/data/mod_month_verified_manifest_v1.dart';
import 'package:moodiary_sync/src/data/model/manifest.dart';

import '../sync_test_harness.dart';

const topicId='aac26e25-4a1d-4b4c-b256-9b0c347d36e2';
const another='45c26e25-4a1d-4b4c-b256-9b0c347d36e2';
const block='block-00000001';
const revision='revision-00000001';

Uint8List bytes(String value) => Uint8List.fromList(utf8.encode(value));
String digest(Object item) => sha256.convert(
    utf8.encode(jsonEncode(item))).toString();

void main() {
  late MoodiaryDatabase db;
  setUp(() async {
    db=MoodiaryDatabase.forTesting(NativeDatabase.memory());
    await db.customSelect('SELECT 1').get();
    await db.customStatement(
      'INSERT INTO mod_month_pages(topic_id,month_key,diary_id,created_ms) '
      'VALUES(?,?,NULL,?)',
      [topicId,'2026-11',100]);
  });
  tearDown(() async {
    await db.close();
  });

  bool isTopic(Diary d) => d.tags.contains('test-long-topic');

  Future<Map<String,Uint8List>> staged({
    bool image=true,
    bool validTopic=true,
    bool attachGraph=false,
    bool missingLegacyImage=false,
    bool boundDiary=false,
  }) async {
    if (attachGraph) {
      final doc=jsonEncode({
        'type':'doc','attrs':{'v':2},
        'content':[
          {'type':'image','attrs':{'src':'history.png'}}
        ],
      });
      final payload=digest([
        block,revision,topicId,'2026-11','entry',null,'2026-11-07',
        100,doc,false,
      ]);
      await db.customStatement(
        'INSERT INTO mod_month_blocks'
        '(block_id,topic_id,month_key,kind,created_ms) VALUES(?,?,?,?,?)',
        [block,topicId,'2026-11','entry',100],
      );
      await db.customStatement(
        'INSERT INTO mod_month_revisions'
        '(revision_id,block_id,parent_revision_id,month_key,day_key,'
        'occurred_at_ms,body_json,deleted,edited_at_ms) '
        'VALUES(?,?,NULL,?,?,?,?,?,?)',
        [revision,block,'2026-11','2026-11-07',100,doc,0,101],
      );
      await db.customStatement(
        'INSERT INTO mod_month_heads(block_id,revision_id) VALUES(?,?)',
        [block,revision],
      );
      await db.customStatement(
        'INSERT INTO mod_month_ops'
        '(operation_id,payload_sha256,block_id,revision_id,applied_at_ms)'
        ' VALUES(?,?,?,?,?)',
        ['operation-00000001',payload,block,revision,101],
      );
    }
    if (boundDiary) {
      await db.customStatement(
        'UPDATE mod_month_pages SET diary_id=? '
        'WHERE topic_id=? AND month_key=?',
        [another,topicId,'2026-11'],
      );
    }
    final t=buildDiary(
      id:topicId,title:'真实长期记录主题',images:image?['topic.png']:[],
    ).copyWith(tags:validTopic?['test-long-topic']:[]);
    final files=<String,Uint8List>{
      ModMonthVerifiedManifestV1.graphPath:
          bytes(await ModMonthGraphArchiveV1.exportGraph(db)),
      'diary/$topicId.json':bytes(jsonEncode(t.toJson())),
    };
    if (image) files['media/image/topic.png']=bytes('binary-png-data');
    if (attachGraph) files['media/image/history.png']=bytes('old-media');
    if (boundDiary) {
      files['diary/$another.json']=bytes(jsonEncode(
          buildDiary(id:another,title:'关联月度原生日记').toJson()));
    }
    final nativeRefs=image&&!missingLegacyImage
        ? ['image/topic.png'] : <String>[];
    final manifest=SyncManifest(
      version:SyncManifest.currentVersion,
      updatedAtMs:123456,
      entries:{
        'd:$topicId':ManifestEntry(timeMs:123,media:nativeRefs),
        if (boundDiary) 'd:$another':const ManifestEntry(timeMs:125),
        'd:deleted-diary-00000001':
            const ManifestEntry(timeMs:120,deleted:true),
      },
    );
    files['manifest.json']=bytes(jsonEncode(manifest.toJson()));
    return files;
  }

  test('full staged topic + ordinary image and graph pass, stable manifest',() async {
    final entries=await staged(attachGraph:true);
    final first=ModMonthVerifiedManifestV1.seal(
      staged:entries,isTopic:isTopic);
    final second=ModMonthVerifiedManifestV1.seal(
      staged:entries,isTopic:isTopic);
    expect(first,second);
    ModMonthVerifiedManifestV1.verify(
      manifest:first,staged:entries,isTopic:isTopic);
    final parsed=jsonDecode(first) as Map<String,dynamic>;
    expect(parsed['topics'],[topicId]);
    final listing=(parsed['files'] as List)
        .map((e)=>(e as Map)['path']).toList();
    expect(listing,containsAll([
      'manifest.json','diary/$topicId.json',
      'media/image/topic.png','media/image/history.png',
      ModMonthVerifiedManifestV1.graphPath,
    ]));
    expect(listing,orderedEquals([...listing]..sort()));
  });

  test('missing historical media fails closed even if native manifest omits it',() async {
    final entries=await staged(attachGraph:true);
    entries.remove('media/image/history.png');
    expect(()=>ModMonthVerifiedManifestV1.seal(staged:entries,isTopic:isTopic),
      throwsA(isA<ModBundleInvalid>().having(
        (e)=>e.code,'code','missing_media_bytes')));
  });

  test('missing existing native image fails even when graph is valid',() async {
    final entries=await staged();
    entries.remove('media/image/topic.png');
    expect(()=>ModMonthVerifiedManifestV1.seal(staged:entries,isTopic:isTopic),
      throwsA(isA<ModBundleInvalid>().having(
        (e)=>e.code,'code','missing_media_bytes')));
  });

  test('native diary media absent from old manifest fails closed',() async {
    final entries=await staged(missingLegacyImage:true);
    expect(()=>ModMonthVerifiedManifestV1.seal(staged:entries,isTopic:isTopic),
      throwsA(isA<ModBundleInvalid>().having(
        (e)=>e.code,'code','missing_native_media_manifest_reference')));
  });

  test('topic must be verified by the app domain predicate, not only by ID',() async {
    final entries=await staged(validTopic:false);
    expect(()=>ModMonthVerifiedManifestV1.seal(staged:entries,isTopic:isTopic),
      throwsA(isA<ModBundleInvalid>().having(
        (e)=>e.code,'code','topic_identity_not_verified')));
  });

  test('tampered media bytes never pass an old sealed manifest',() async {
    final entries=await staged();
    final sealed=ModMonthVerifiedManifestV1.seal(
      staged:entries,isTopic:isTopic);
    entries['media/image/topic.png']=bytes('different-contents');
    expect(()=>ModMonthVerifiedManifestV1.verify(
      manifest:sealed,staged:entries,isTopic:isTopic),
      throwsA(isA<ModBundleInvalid>().having(
        (e)=>e.code,'code','bundle_integrity_mismatch')));
  });

  test('removed topic diary cannot be backed up by only its graph',() async {
    final entries=await staged();
    entries.remove('diary/$topicId.json');
    expect(()=>ModMonthVerifiedManifestV1.seal(staged:entries,isTopic:isTopic),
      throwsA(isA<ModBundleInvalid>().having(
        (e)=>e.code,'code','missing_native_entity')));
  });

  test('already-bound native monthly diary must exist in same archive',() async {
    final entries=await staged(boundDiary:true);
    entries.remove('diary/$another.json');
    expect(()=>ModMonthVerifiedManifestV1.seal(staged:entries,isTopic:isTopic),
      throwsA(isA<ModBundleInvalid>().having(
        (e)=>e.code,'code','missing_native_entity')));
  });

  test('reject traversal and misplaced binary payload path',() async {
    final entries=await staged();
    entries['media/image/../escape.jpg']=bytes('not-safe');
    expect(()=>ModMonthVerifiedManifestV1.seal(staged:entries,isTopic:isTopic),
      throwsA(isA<ModBundleInvalid>().having(
        (e)=>e.code,'code','unsafe_archive_path')));
  });

  test('reject extra native diary outside the legacy manifest',() async {
    final entries=await staged();
    entries['diary/$another.json']=bytes(jsonEncode(
      buildDiary(id:another).toJson()));
    expect(()=>ModMonthVerifiedManifestV1.seal(staged:entries,isTopic:isTopic),
      throwsA(isA<ModBundleInvalid>().having(
        (e)=>e.code,'code','orphan_entity_payload')));
  });

  test('unknown future Tiptap src reference cannot silently disappear',() async {
    final entries=await staged(attachGraph:true);
    final graph=jsonDecode(utf8.decode(entries[
        ModMonthVerifiedManifestV1.graphPath]!)) as Map<String,dynamic>;
    final tables=graph['tables'] as Map<String,dynamic>;
    final revisionRow=(tables['mod_month_revisions'] as List).single
        as Map<String,dynamic>;
    final doc=jsonDecode(revisionRow['body_json'] as String)
        as Map<String,dynamic>;
    (doc['content'] as List).single['type']='futureMediaNode';
    revisionRow['body_json']=jsonEncode(doc);
    // Even with a forged parent archive checksum and op fingerprint,
    // validation must reject unknown src nodes before sealing.
    final operation=(tables['mod_month_ops'] as List).single
        as Map<String,dynamic>;
    operation['payload_sha256']=digest([
      block,revision,topicId,'2026-11','entry',null,'2026-11-07',
      100,revisionRow['body_json'],false,
    ]);
    graph['sha256']=digest({
      'format':graph['format'],'version':graph['version'],'tables':tables,
    });
    entries[ModMonthVerifiedManifestV1.graphPath]=bytes(jsonEncode(graph));
    expect(()=>ModMonthVerifiedManifestV1.seal(staged:entries,isTopic:isTopic),
      throwsA(isA<ModBundleInvalid>().having(
        (e)=>e.code,'code','unknown_media_node')));
  });

  test('no source mutation occurs during sealing or failure',() async {
    final entries=await staged();
    final before={
      for (final e in entries.entries)e.key:List<int>.from(e.value),
    };
    ModMonthVerifiedManifestV1.seal(staged:entries,isTopic:isTopic);
    expect(entries.keys.toSet(),before.keys.toSet());
    for (final k in entries.keys) {
      expect(entries[k],orderedEquals(before[k]!));
    }
  });
}
