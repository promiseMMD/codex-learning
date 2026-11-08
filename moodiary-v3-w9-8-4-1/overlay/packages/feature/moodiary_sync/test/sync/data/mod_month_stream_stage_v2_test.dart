import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moodiary_data/moodiary_data.dart';
import 'package:moodiary_models/moodiary_models.dart';
import 'package:moodiary_sync/src/data/impl/local_archive.dart';
import 'package:moodiary_sync/src/data/mod_month_stream_stage_v2.dart';
import 'package:moodiary_sync/src/data/mod_month_verified_manifest_v2.dart';
import 'package:moodiary_sync/src/data/mod_month_verified_manifest_v1.dart';

import '../sync_test_harness.dart';

const topic='aac26e25-4a1d-4b4c-b256-9b0c347d36e2';
const block='block-00000001';
const revision='revision-00000001';
const day='2026-11-07';
Uint8List utf(String text)=>Uint8List.fromList(utf8.encode(text));
String sha(Object item)=>sha256.convert(utf8.encode(jsonEncode(item))).toString();
bool isTopic(Diary d)=>d.tags.contains('test-long-topic');

Future<void> seed(MoodiaryDatabase db) async {
  final doc=jsonEncode({'type':'doc','attrs':{'v':2},'content':[
    {'type':'image','attrs':{'src':'history.png'}}]});
  await db.customStatement(
    'INSERT INTO mod_month_pages'
    '(topic_id,month_key,diary_id,created_ms) VALUES(?,?,NULL,?)',
    [topic,'2026-11',10]);
  await db.customStatement(
    'INSERT INTO mod_month_blocks'
    '(block_id,topic_id,month_key,kind,created_ms) VALUES(?,?,?,?,?)',
    [block,topic,'2026-11','entry',11]);
  await db.customStatement(
    'INSERT INTO mod_month_revisions'
    '(revision_id,block_id,parent_revision_id,month_key,day_key,'
    'occurred_at_ms,body_json,deleted,edited_at_ms)'
    ' VALUES(?,?,NULL,?,?,?,?,?,?)',
    [revision,block,'2026-11',day,12,doc,0,13]);
  await db.customStatement(
    'INSERT INTO mod_month_heads(block_id,revision_id) VALUES(?,?)',
    [block,revision]);
  await db.customStatement(
    'INSERT INTO mod_month_ops'
    '(operation_id,payload_sha256,block_id,revision_id,applied_at_ms)'
    ' VALUES(?,?,?,?,?)',
    ['operation-0001',
     sha([block,revision,topic,'2026-11','entry',null,day,12,doc,false]),
     block,revision,13]);
  await db.customStatement(
    'INSERT INTO mod_day_pages'
    '(topic_id,day_key,diary_id,visible_local,created_ms)'
    ' VALUES(?,?,NULL,0,?)',
    [topic,day,14]);
}

void main(){
  late Directory scratch;
  late MoodiaryDatabase db;
  setUp(() async {
    scratch=await Directory.systemTemp.createTemp('w9841-stream-');
    db=MoodiaryDatabase.forTesting(NativeDatabase.memory());
    await db.customSelect('SELECT 1').get();
    await seed(db);
  });
  tearDown(() async {
    await db.close();
    if(await scratch.exists())await scratch.delete(recursive:true);
  });

  Future<ModMonthStreamStageV2> stage({bool withHistory=true}) async {
    final archive=await ModMonthStreamStageV2.create(
      scratch.path+'/sealed');
    final mediaRoot=Directory(scratch.path+'/media-source');
    await mediaRoot.create();
    final picture=File(mediaRoot.path+'/image/native.png');
    await picture.parent.create(recursive:true);
    await picture.writeAsBytes([137,80,78,71,1,2,3],flush:true);
    final t=buildDiary(id:topic,title:'长期记录',
      images:['native.png']).copyWith(tags:['test-long-topic']);
    await LocalArchive.writeArchive(
      sink:archive,diaries:[t],categories:const [],tombstones:const [],
      mediaBaseDir:mediaRoot.path);
    if(withHistory) {
      await archive.addBytes('media/image/history.png',
        Uint8List.fromList([10,11,12,13]));
    }
    await archive.addBytes(ModMonthVerifiedManifestV2.graphPath,
      utf(await ModMonthGraphArchiveV2.exportGraph(db)));
    return archive;
  }

  test('real LocalArchive, media and daily GraphV2 seal and atomic publish', () async {
    final archive=await stage();
    expect(await Directory(archive.destinationPath).exists(),false);
    final published=await archive.publish(isTopic:isTopic);
    expect(published,archive.destinationPath);
    expect(await Directory(archive.stagingPath).exists(),false);
    await ModMonthStreamStageV2.verifyPublished(
      published,isTopic:isTopic);
    final proof=jsonDecode(await File(
      published+'/'+ModMonthStreamStageV2.manifestPath)
      .readAsString()) as Map<String,dynamic>;
    expect(proof['format'],ModMonthVerifiedManifestV2.format);
    final files=proof['files'] as List<dynamic>;
    expect(files.map((e)=>e['path']),containsAll([
      'manifest.json','diary/$topic.json','media/image/native.png',
      'media/image/history.png',ModMonthVerifiedManifestV2.graphPath,
    ]));
    expect(await File(published+'/media/image/history.png').readAsBytes(),
      orderedEquals([10,11,12,13]));
    expect(await Directory(published).exists(),true);
  });

  test('historical media missing fails before publication and cleans stage',() async {
    final archive=await stage(withHistory:false);
    await expectLater(archive.publish(isTopic:isTopic),
      throwsA(isA<ModBundleInvalid>().having(
        (e)=>e.code,'code','missing_media_bytes')));
    expect(await Directory(archive.destinationPath).exists(),false);
    expect(await Directory(archive.stagingPath).exists(),false);
  });

  test('media corruption after seal is detected from independently hashed file',() async {
    final archive=await stage();
    final dir=await archive.publish(isTopic:isTopic);
    await File(dir+'/media/image/history.png').writeAsBytes([2,3,4],flush:true);
    await expectLater(ModMonthStreamStageV2.verifyPublished(
      dir,isTopic:isTopic),
      throwsA(isA<ModBundleInvalid>().having(
        (e)=>e.code,'code','v2_bundle_integrity_mismatch')));
  });

  test('inject symlink before publication, preserve unrelated source',() async {
    final archive=await stage();
    final outside=File(scratch.path+'/unrelated.txt');
    await outside.writeAsString('safe',flush:true);
    await Link(archive.stagingPath+'/media/image/linked.png')
      .create(outside.path);
    await expectLater(archive.publish(isTopic:isTopic),
      throwsA(isA<ModBundleInvalid>().having(
        (e)=>e.code,'code','unsafe_archive_symlink')));
    expect(await outside.readAsString(),'safe');
    expect(await Directory(archive.destinationPath).exists(),false);
  });

  test('partial graph mutation and destination collision never overwrite existing data',() async {
    final archive=await stage();
    final graph=File(
      archive.stagingPath+'/'+ModMonthVerifiedManifestV2.graphPath);
    await graph.writeAsString('{"forged":true}',flush:true);
    await expectLater(archive.publish(isTopic:isTopic),
      throwsA(isA<ModBundleInvalid>().having(
        (e)=>e.code,'code','staged_file_changed')));
    expect(await Directory(archive.destinationPath).exists(),false);
    final second=await stage();
    await Directory(second.destinationPath).create();
    final keep=File(second.destinationPath+'/keep.txt');
    await keep.writeAsString('not overwritten');
    await expectLater(second.publish(isTopic:isTopic),
      throwsA(isA<ModBundleInvalid>().having(
        (e)=>e.code,'code','target_already_exists')));
    expect(await keep.readAsString(),'not overwritten');
  });

  test('refuse old V1 graph path and duplicate file names, never overwrite',() async {
    final archive=await stage();
    await expectLater(archive.addBytes(
      ModMonthVerifiedManifestV1.graphPath,utf('old')),
      throwsA(isA<ModBundleInvalid>().having(
        (e)=>e.code,'code','unsafe_archive_path')));
    expect(await Directory(archive.stagingPath).exists(),false);
    final second=await stage();
    await expectLater(second.addBytes(
      'diary/$topic.json',utf('overwritten')),
      throwsA(isA<ModBundleInvalid>().having(
        (e)=>e.code,'code','duplicate_file_path')));
    expect(await Directory(second.destinationPath).exists(),false);
  });
}
