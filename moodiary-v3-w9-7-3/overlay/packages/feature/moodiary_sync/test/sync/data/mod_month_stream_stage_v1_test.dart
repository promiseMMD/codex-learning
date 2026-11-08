import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moodiary_data/moodiary_data.dart';
import 'package:moodiary_models/moodiary_models.dart';
import 'package:moodiary_sync/src/data/impl/local_archive.dart';
import 'package:moodiary_sync/src/data/mod_month_stream_stage_v1.dart';
import 'package:moodiary_sync/src/data/mod_month_verified_manifest_v1.dart';

import '../sync_test_harness.dart';

const topicId='aac26e25-4a1d-4b4c-b256-9b0c347d36e2';

Uint8List utf(String text) => Uint8List.fromList(utf8.encode(text));

void main() {
  late Directory scratch;
  late MoodiaryDatabase db;

  bool isTopic(Diary diary) => diary.tags.contains('test-long-topic');

  setUp(() async {
    scratch=await Directory.systemTemp.createTemp('w973-test-');
    db=MoodiaryDatabase.forTesting(NativeDatabase.memory());
    await db.customSelect('SELECT 1').get();
    await db.customStatement(
      'INSERT INTO mod_month_pages(topic_id,month_key,diary_id,created_ms)'
      ' VALUES(?,?,NULL,?)',[topicId,'2026-11',100]);
  });

  tearDown(() async {
    await db.close();
    if (await scratch.exists()) await scratch.delete(recursive:true);
  });

  Future<ModMonthStreamStageV1> stage({
    bool withImage=true,
    bool validTopic=true,
  }) async {
    final stage=await ModMonthStreamStageV1.create(
      scratch.path+'/verified');
    final mediaBase=Directory(scratch.path+'/source');
    await mediaBase.create(recursive:true);
    if (withImage) {
      final f=File(mediaBase.path+'/image/topic.png');
      await f.parent.create(recursive:true);
      await f.writeAsBytes([137,80,78,71,1,2,3,4],flush:true);
    }
    final native=buildDiary(id:topicId,title:'完整主题',
      images:withImage?['topic.png']:[]);
    final diary=native.copyWith(
      tags:validTopic?['test-long-topic']:[]);
    await LocalArchive.writeArchive(
      sink:stage,diaries:[diary],categories:const [],
      tombstones:const [],mediaBaseDir:mediaBase.path);
    await stage.addBytes(ModMonthVerifiedManifestV1.graphPath,
      utf(await ModMonthGraphArchiveV1.exportGraph(db)));
    return stage;
  }

  test('real LocalArchive stream, W9 graph and media are atomically published',
      () async {
    final archive=await stage();
    expect(await Directory(archive.stagingPath).exists(),isTrue);
    expect(await Directory(archive.destinationPath).exists(),isFalse);
    final output=await archive.publish(isTopic:isTopic);
    expect(output,archive.destinationPath);
    expect(await Directory(output).exists(),isTrue);
    expect(await Directory(archive.stagingPath).exists(),isFalse);
    await ModMonthStreamStageV1.verifyPublished(output,isTopic:isTopic);
    final receipt=File(output+'/'+ModMonthStreamStageV1.manifestPath);
    expect(await receipt.exists(),isTrue);
    final value=jsonDecode(await receipt.readAsString())
        as Map<String,dynamic>;
    expect(value['format'],ModMonthVerifiedManifestV1.format);
    expect((value['files'] as List).length,4);
    expect(await File(output+'/media/image/topic.png').readAsBytes(),
      orderedEquals([137,80,78,71,1,2,3,4]));
    // Byte-identical to the older in-memory closure contract on small files.
    final staging=<String,Uint8List>{};
    for (final path in [
      'manifest.json','diary/$topicId.json',
      'media/image/topic.png',ModMonthVerifiedManifestV1.graphPath,
    ]) {
      staging[path]=await File(output+'/'+path).readAsBytes();
    }
    expect(await receipt.readAsString(),
      ModMonthVerifiedManifestV1.seal(staged:staging,isTopic:isTopic));
    expect(()=>archive.addBytes('manifest.json',utf('again')),
      throwsA(isA<ModBundleInvalid>()));
  });

  test('streaming stages media larger than previous in-memory 256 MiB limit',
      () async {
    final archive=await stage(withImage:false);
    final media=File(scratch.path+'/giant-video.mp4');
    final handle=await media.open(mode:FileMode.write);
    // Sparse test source. Copy and SHA must stream, never read into RAM.
    const large=257*1024*1024;
    await handle.truncate(large);
    await handle.close();
    await archive.addLocalFile('media/video/giant-video.mp4',media.path);
    final dir=await archive.publish(isTopic:isTopic);
    expect(await File(dir+'/media/video/giant-video.mp4').length(),large);
    await ModMonthStreamStageV1.verifyPublished(dir,isTopic:isTopic);
    expect(await Directory(dir).exists(),isTrue);
  });

  test('changed media after publish invalidates sealed archive',() async {
    final archive=await stage();
    final dir=await archive.publish(isTopic:isTopic);
    final f=File(dir+'/media/image/topic.png');
    await f.writeAsBytes([0,1,2],flush:true);
    await expectLater(
      ModMonthStreamStageV1.verifyPublished(dir,isTopic:isTopic),
      throwsA(isA<ModBundleInvalid>().having(
        (error)=>error.code,'code','bundle_integrity_mismatch')));
  });

  test('tamper before publish discards quarantine without new target',() async {
    final archive=await stage();
    final partialRoot=archive.stagingPath;
    await File(partialRoot+'/media/image/topic.png')
      .writeAsBytes([1,2,3],flush:true);
    await expectLater(archive.publish(isTopic:isTopic),
      throwsA(isA<ModBundleInvalid>().having(
        (e)=>e.code,'code','staged_file_changed')));
    expect(await Directory(partialRoot).exists(),isFalse);
    expect(await Directory(archive.destinationPath).exists(),isFalse);
  });

  test('missing Topic identity aborts; raw month tables cannot be backup',() async {
    final archive=await stage(validTopic:false);
    await expectLater(archive.publish(isTopic:isTopic),
      throwsA(isA<ModBundleInvalid>().having(
        (e)=>e.code,'code','topic_identity_not_verified')));
    expect(await Directory(archive.destinationPath).exists(),isFalse);
    expect(await Directory(archive.stagingPath).exists(),isFalse);
  });

  test('path traversal aborts and removes the entire private stage',() async {
    final archive=await stage();
    await expectLater(
      archive.addBytes('media/image/../../overwrite.jpg',utf('bad')),
      throwsA(isA<ModBundleInvalid>().having(
        (e)=>e.code,'code','unsafe_archive_path')));
    expect(await Directory(archive.stagingPath).exists(),isFalse);
    expect(await Directory(archive.destinationPath).exists(),isFalse);
  });

  test('duplicate file name never silently overwrites staged diary',() async {
    final archive=await stage();
    await expectLater(
      archive.addBytes('diary/$topicId.json',utf('overwritten')),
      throwsA(isA<ModBundleInvalid>().having(
        (e)=>e.code,'code','duplicate_file_path')));
    expect(await Directory(archive.stagingPath).exists(),isFalse);
  });

  test('symlink injection aborts staging, never follows it',() async {
    final archive=await stage();
    final source=File(scratch.path+'/outside.txt');
    await source.writeAsString('outside-data');
    final link=Link(archive.stagingPath+'/media/image/link.png');
    await link.create(source.path);
    await expectLater(archive.publish(isTopic:isTopic),
      throwsA(isA<ModBundleInvalid>().having(
        (e)=>e.code,'code','unsafe_archive_symlink')));
    expect(await source.readAsString(),'outside-data');
    expect(await Directory(archive.stagingPath).exists(),isFalse);
  });

  test('extra unindexed staged file aborts entire staged output',() async {
    final archive=await stage();
    await File(archive.stagingPath+'/diary/stray.json')
        .writeAsString('unlisted');
    await expectLater(archive.publish(isTopic:isTopic),
      throwsA(isA<ModBundleInvalid>().having(
        (e)=>e.code,'code','staged_file_set_changed')));
    expect(await Directory(archive.stagingPath).exists(),isFalse);
  });

  test('existing target is never overwritten on destination collision',() async {
    final archive=await stage();
    final dst=Directory(archive.destinationPath);
    await dst.create();
    final keep=File(dst.path+'/keep.txt');
    await keep.writeAsString('must survive');
    await expectLater(archive.publish(isTopic:isTopic),
      throwsA(isA<ModBundleInvalid>().having(
        (e)=>e.code,'code','target_already_exists')));
    expect(await keep.readAsString(),'must survive');
    expect(await Directory(archive.stagingPath).exists(),isFalse);
  });

  test('reject symlinked source before reading private file',() async {
    final archive=await stage();
    final real=File(scratch.path+'/secret.txt');
    await real.writeAsString('do not follow');
    final link=Link(scratch.path+'/fake.png');
    await link.create(real.path);
    await expectLater(
      archive.addLocalFile('media/image/fake.png',link.path),
      throwsA(isA<ModBundleInvalid>().having(
        (e)=>e.code,'code','unsafe_source_file')));
    expect(await real.readAsString(),'do not follow');
    expect(await Directory(archive.stagingPath).exists(),isFalse);
  });

  test('published directories remain untouched by a later abort',() async {
    final archive=await stage();
    final dir=await archive.publish(isTopic:isTopic);
    await archive.abort();
    expect(await Directory(dir).exists(),isTrue);
    await ModMonthStreamStageV1.verifyPublished(dir,isTopic:isTopic);
  });
}
