import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moodiary_data/moodiary_data.dart';
import 'package:moodiary_models/moodiary_models.dart';
import 'package:moodiary_sync/src/data/impl/local_archive.dart';
import 'package:moodiary_sync/src/data/mod_month_isolated_restore_v1.dart';
import 'package:moodiary_sync/src/data/mod_month_stream_stage_v1.dart';
import 'package:moodiary_sync/src/data/mod_month_verified_manifest_v1.dart';
import 'package:moodiary_sync/src/data/mod_month_zip_bundle_v1.dart';

import '../sync_test_harness.dart';

const topicId='aac26e25-4a1d-4b4c-b256-9b0c347d36e2';
const ordinaryId='45c26e25-4a1d-4b4c-b256-9b0c347d36e2';
const categoryId='4ba27777-7a1d-4b4c-b256-9b0c347d36e2';
const placeId='9c9f1255-4a1d-4b4c-b256-9b0c347d36e2';
const blockId='entry-block-0001';
const rootId='revision-root-0001';
const movedId='revision-moved-0001';
const summaryId='summary-block-0001';
const summaryRevision='revision-summary-0001';

Uint8List utf(String text) => Uint8List.fromList(utf8.encode(text));
String digest(Object item) =>
  sha256.convert(utf8.encode(jsonEncode(item))).toString();

String doc(String content,{String? image}) => jsonEncode({
  'type':'doc','attrs':{'v':2},
  'content':[
    {'type':'paragraph','content':[{'type':'text','text':content}]},
    if (image!=null) {'type':'image','attrs':{'src':image}},
  ],
});

final class _PythonZipTransport implements ModMonthZipTransportV1 {
  const _PythonZipTransport();
  static Future<void> _python(List<String> args) async {
    final result=await Process.run('python3',args);
    if (result.exitCode!=0) throw StateError(
      'zip fixture failure: '+result.stderr.toString());
  }
  @override
  Future<void> create({
    required String archivePath,
    required String sourceDirectory,
    required List<String> entries,
  }) => _python(['-c',r'''
import os,sys,zipfile
dest,root,*items=sys.argv[1:]
with zipfile.ZipFile(dest,'w',allowZip64=True) as z:
    for name in items:
        z.write(os.path.join(root,*name.split('/')),arcname=name,
                compress_type=zipfile.ZIP_STORED)
''',archivePath,sourceDirectory,...entries]);

  @override
  Future<void> extract({
    required String archivePath,
    required String destinationDirectory,
  }) => _python(['-c',r'''
import sys,zipfile
with zipfile.ZipFile(sys.argv[1]) as z:
    z.extractall(sys.argv[2])
''',archivePath,destinationDirectory]);
}

void main() {
  late Directory sandbox;
  late MoodiaryDatabase source;
  const transport=_PythonZipTransport();

  bool isTopic(Diary diary)=>diary.tags.contains('test-long-topic');

  setUp(() async {
    sandbox=await Directory.systemTemp.createTemp('w975-restore-test-');
    source=MoodiaryDatabase.forTesting(NativeDatabase.memory());
    await source.customSelect('SELECT 1').get();
  });

  tearDown(() async {
    await source.close();
    if (await sandbox.exists()) await sandbox.delete(recursive:true);
  });

  Future<void> seedGraph() async {
    for (final month in ['2026-11','2026-12']) {
      await source.customStatement(
        'INSERT INTO mod_month_pages'
        '(topic_id,month_key,diary_id,created_ms) VALUES(?,?,?,?)',
        [topicId,month,month=='2026-12'?ordinaryId:null,100]);
    }
    for (final (block,month,kind) in [
      (blockId,'2026-11','entry'),(summaryId,'2026-11','summary'),
    ]) {
      await source.customStatement(
        'INSERT INTO mod_month_blocks'
        '(block_id,topic_id,month_key,kind,created_ms) VALUES(?,?,?,?,?)',
        [block,topicId,month,kind,101]);
    }
    Future<void> add({
      required String revision,
      required String block,
      String? parent,
      required String kind,
      required String month,
      String? day,
      required String content,
      bool deleted=false,
      required int time,
    }) async {
      await source.customStatement(
        'INSERT INTO mod_month_revisions'
        '(revision_id,block_id,parent_revision_id,month_key,day_key,'
        'occurred_at_ms,body_json,deleted,edited_at_ms)'
        ' VALUES(?,?,?,?,?,?,?,?,?)',
        [revision,block,parent,month,day,time,content,deleted?1:0,time+10]);
      await source.customStatement(
        'INSERT INTO mod_month_ops'
        '(operation_id,payload_sha256,block_id,revision_id,applied_at_ms)'
        ' VALUES(?,?,?,?,?)',
        ['operation-'+revision,
          digest([block,revision,topicId,month,kind,parent,day,time,
            content,deleted]),block,revision,time+10]);
    }
    await add(revision:rootId,block:blockId,kind:'entry',
      month:'2026-11',day:'2026-11-07',
      content:doc('跨月前内容',image:'history.png'),time:200);
    await add(revision:movedId,block:blockId,parent:rootId,kind:'entry',
      month:'2026-12',day:'2026-12-01',
      content:doc('删除但保留修订历史'),deleted:true,time:300);
    await add(revision:summaryRevision,block:summaryId,kind:'summary',
      month:'2026-11',content:doc('十一月总结'),time:400);
    for (final (block,revision) in [
      (blockId,movedId),(summaryId,summaryRevision),
    ]) {
      await source.customStatement(
        'INSERT INTO mod_month_heads(block_id,revision_id) VALUES(?,?)',
        [block,revision]);
    }
  }

  Future<String> buildZip() async {
    await seedGraph();
    final writer=await ModMonthStreamStageV1.create(
      sandbox.path+'/verified-directory');
    final media=Directory(sandbox.path+'/original-media');
    final current=File(media.path+'/image/current.png');
    final old=File(media.path+'/image/history.png');
    await current.parent.create(recursive:true);
    await current.writeAsBytes([137,80,78,71,1,1,2,3],flush:true);
    await old.writeAsBytes([137,80,78,71,9,8,7,6],flush:true);
    final topic=buildDiary(id:topicId,title:'长期记录主题',
      images:['current.png']).copyWith(tags:['test-long-topic']);
    final ordinary=buildDiary(id:ordinaryId,categoryId:categoryId,
      title:'普通日记',modifiedMs:123);
    final category=buildCategory(id:categoryId,name:'生活',modifiedMs:121);
    final place=Place(id:placeId,name:'某个地点',latitude:34.0,
      longitude:110.5,lastModified:DateTime.utc(2026,11,8));
    await LocalArchive.writeArchive(
      sink:writer,diaries:[topic,ordinary],categories:[category],
      places:[place],
      tombstones:[buildDiaryTombstone(
        'e24f1abe-1111-4444-8888-000000000001',modifiedMs:150)],
      mediaBaseDir:media.path);
    // Historical media must be included even after the latest revision was
    // deleted: the legacy diary media list alone is not sufficient.
    await writer.addLocalFile('media/image/history.png',old.path);
    await writer.addBytes(ModMonthVerifiedManifestV1.graphPath,
      utf(await ModMonthGraphArchiveV1.exportGraph(source)));
    final verified=await writer.publish(isTopic:isTopic);
    return ModMonthZipBundleV1.createVerified(
      sourceDirectory:verified,
      outputZip:sandbox.path+'/archive.zip',
      isTopic:isTopic,transport:transport);
  }

  Future<int> count(MoodiaryDatabase db,String table) async =>
    (await db.customSelect('SELECT COUNT(*) AS n FROM '+table)
      .getSingle()).read<int>('n');

  test('full ZIP restore: native Diary/category/place/tombstone + W9 DAG + old media',
      () async {
    final zip=await buildZip();
    final restored=await ModMonthIsolatedRestoreV1
      .restoreZipToNewIsolatedDirectory(
        zipPath:zip,outputDirectory:sandbox.path+'/new-device',
        isTopic:isTopic,transport:transport);
    expect(restored,sandbox.path+'/new-device');
    expect((jsonDecode(await File(restored+'/restore-state.json')
      .readAsString()) as Map)['phase'],'ready');
    final db=MoodiaryDatabase.forTesting(NativeDatabase(
      File(restored+'/database/restored.sqlite')));
    try {
      await db.customSelect('SELECT 1').get();
      expect(await count(db,'diaries'),2);
      expect(await count(db,'categories'),1);
      expect(await count(db,'places'),1);
      expect(await count(db,'diary_media'),1);
      expect(await count(db,'diary_tags'),1);
      expect(await count(db,'tombstones'),1);
      expect(await count(db,'mod_month_pages'),2);
      expect(await count(db,'mod_month_blocks'),2);
      expect(await count(db,'mod_month_revisions'),3);
      expect(await count(db,'mod_month_heads'),2);
      expect(await count(db,'mod_month_ops'),3);
      expect(await ModMonthGraphArchiveV1.exportGraph(db),
        await ModMonthGraphArchiveV1.exportGraph(source));
      final all=await DiaryRepository(db).getAllDiaries();
      expect(all.map((d)=>d.title),containsAll(['长期记录主题','普通日记']));
      expect(all.firstWhere((d)=>d.id==topicId).tags,['test-long-topic']);
      expect((await db.customSelect(
        'SELECT pushed_backends_json FROM tombstones').getSingle())
        .read<String>('pushed_backends_json'),'[]');
    } finally {
      await db.close();
    }
    expect(await File(restored+'/media/image/current.png').readAsBytes(),
      orderedEquals([137,80,78,71,1,1,2,3]));
    expect(await File(restored+'/media/image/history.png').readAsBytes(),
      orderedEquals([137,80,78,71,9,8,7,6]));
    expect(await Directory(restored+'/verified-input').exists(),isFalse);
  });

  test('fault injection at every restore boundary cleans private state',
      () async {
    final zip=await buildZip();
    for (final phase in [
      'source_verified','graph_restored','native_restored',
      'media_restored','readback_complete','before_publish',
    ]) {
      final target=sandbox.path+'/fail-'+phase;
      await expectLater(
        ModMonthIsolatedRestoreV1.restoreZipToNewIsolatedDirectory(
          zipPath:zip,outputDirectory:target,
          isTopic:isTopic,transport:transport,
          checkpoint:(value) async {
            if (value==phase) throw StateError('injected crash at '+phase);
          },
        ),
        throwsA(isA<StateError>()));
      expect(await Directory(target).exists(),isFalse,
        reason:'phase '+phase+' must never publish partial restore');
      final leftovers=await sandbox.list(followLinks:false)
        .where((entry)=>entry.path.contains('.moodiary-w975-')).toList();
      expect(leftovers,isEmpty,reason:'no leaked restore staging at '+phase);
      expect(await File(zip).exists(),isTrue);
    }
  });

  test('pre-existing destination survives attempted restore intact',() async {
    final zip=await buildZip();
    final target=Directory(sandbox.path+'/already-has-diaries');
    await target.create();
    final old=File(target.path+'/diary.txt');
    await old.writeAsString('real user diary, never touch');
    await expectLater(
      ModMonthIsolatedRestoreV1.restoreZipToNewIsolatedDirectory(
        zipPath:zip,outputDirectory:target.path,
        isTopic:isTopic,transport:transport),
      throwsA(isA<ModBundleInvalid>().having(
        (e)=>e.code,'code','restore_destination_exists')));
    expect(await old.readAsString(),'real user diary, never touch');
  });

  test('tampered ZIP is rejected before isolated DB is published',() async {
    final zip=await buildZip();
    final data=await File(zip).readAsBytes();
    final bad=File(sandbox.path+'/tampered.zip');
    await bad.writeAsBytes(data.sublist(0,data.length~/2));
    final output=sandbox.path+'/bad-output';
    await expectLater(
      ModMonthIsolatedRestoreV1.restoreZipToNewIsolatedDirectory(
        zipPath:bad.path,outputDirectory:output,
        isTopic:isTopic,transport:transport),
      throwsA(isA<ModBundleInvalid>()));
    expect(await Directory(output).exists(),isFalse);
  });

  test('second restore does not merge, replace, or overwrite the first',() async {
    final zip=await buildZip();
    final target=sandbox.path+'/once';
    await ModMonthIsolatedRestoreV1.restoreZipToNewIsolatedDirectory(
      zipPath:zip,outputDirectory:target,
      isTopic:isTopic,transport:transport);
    final before=await File(target+'/database/restored.sqlite').length();
    await expectLater(ModMonthIsolatedRestoreV1
      .restoreZipToNewIsolatedDirectory(
        zipPath:zip,outputDirectory:target,
        isTopic:isTopic,transport:transport),
      throwsA(isA<ModBundleInvalid>()));
    expect(await File(target+'/database/restored.sqlite').length(),before);
  });
}
