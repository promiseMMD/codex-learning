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
import 'package:moodiary_sync/src/data/mod_month_zip_bundle_v1.dart';
import 'package:moodiary_sync/src/data/mod_month_zip_preflight_v1.dart';

import '../sync_test_harness.dart';

const topicId='aac26e25-4a1d-4b4c-b256-9b0c347d36e2';

Uint8List textBytes(String s) => Uint8List.fromList(utf8.encode(s));

/// Test-only real ZIP codec, independent of Flutter Rust binary initialization.
/// Production ModMonthNativeZipTransportV1 uses upstream fast_zip.
final class _PythonZipTransport implements ModMonthZipTransportV1 {
  const _PythonZipTransport();
  static const _write = r'''
import os, sys, zipfile
dest, root, *entries = sys.argv[1:]
with zipfile.ZipFile(dest, 'w', allowZip64=True) as z:
    for name in entries:
        z.write(os.path.join(root, *name.split('/')), arcname=name,
                compress_type=zipfile.ZIP_STORED)
''';
  static const _extract = r'''
import sys,zipfile
with zipfile.ZipFile(sys.argv[1], 'r') as z:
    z.extractall(sys.argv[2])
''';

  static Future<void> execute(List<String> argv) async {
    final result=await Process.run('python3',argv);
    if (result.exitCode!=0) {
      throw StateError('test ZIP command failed: ' +
          result.stderr.toString());
    }
  }

  @override
  Future<void> create({
    required String archivePath,
    required String sourceDirectory,
    required List<String> entries,
  }) => execute(['-c',_write,archivePath,sourceDirectory,...entries]);

  @override
  Future<void> extract({
    required String archivePath,
    required String destinationDirectory,
  }) => execute(['-c',_extract,archivePath,destinationDirectory]);
}

final class _ModifyingTransport implements ModMonthZipTransportV1 {
  const _ModifyingTransport();
  final _PythonZipTransport inner=const _PythonZipTransport();

  @override
  Future<void> create({
    required String archivePath,
    required String sourceDirectory,
    required List<String> entries,
  }) => inner.create(archivePath:archivePath,
    sourceDirectory:sourceDirectory,entries:entries);

  @override
  Future<void> extract({
    required String archivePath,
    required String destinationDirectory,
  }) async {
    await inner.extract(archivePath:archivePath,
      destinationDirectory:destinationDirectory);
    final file=File(destinationDirectory+'/media/image/photo.png');
    if (await file.exists()) await file.writeAsBytes([9,9,9],flush:true);
  }
}

void main() {
  late Directory scratch;
  late MoodiaryDatabase db;

  bool isTopic(Diary diary) => diary.tags.contains('test-long-topic');

  setUp(() async {
    scratch=await Directory.systemTemp.createTemp('w974-test-');
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

  Future<String> stage() async {
    final writer=await ModMonthStreamStageV1.create(
      scratch.path+'/sealed-native');
    final base=Directory(scratch.path+'/media-source');
    final file=File(base.path+'/image/photo.png');
    await file.parent.create(recursive:true);
    await file.writeAsBytes([137,80,78,71,1,2,3],flush:true);
    final diary=buildDiary(id:topicId,
      images:['photo.png'],title:'长期记录原生主题')
        .copyWith(tags:['test-long-topic']);
    await LocalArchive.writeArchive(
      sink:writer,diaries:[diary],categories:const [],
      tombstones:const [],mediaBaseDir:base.path);
    await writer.addBytes(ModMonthVerifiedManifestV1.graphPath,
      textBytes(await ModMonthGraphArchiveV1.exportGraph(db)));
    return writer.publish(isTopic:isTopic);
  }

  Future<String> createZip() async {
    final source=await stage();
    return ModMonthZipBundleV1.createVerified(
      sourceDirectory:source,
      outputZip:scratch.path+'/moodiary.zip',
      isTopic:isTopic,
      transport:const _PythonZipTransport());
  }

  test('verified native+structured+image ZIP round trip into isolated output',
      () async {
    final zip=await createZip();
    final names=await ModMonthZipPreflightV1.inspect(zip);
    expect(names,containsAll([
      'verified-bundle.json','manifest.json',
      ModMonthVerifiedManifestV1.graphPath,
      'diary/$topicId.json','media/image/photo.png',
    ]));
    final extracted=await ModMonthZipBundleV1
        .extractVerifiedIntoIsolatedDirectory(
      zipPath:zip,outputDirectory:scratch.path+'/isolated',
      isTopic:isTopic,transport:const _PythonZipTransport());
    await ModMonthStreamStageV1.verifyPublished(extracted,isTopic:isTopic);
    expect(await File(extracted+'/media/image/photo.png').readAsBytes(),
      orderedEquals([137,80,78,71,1,2,3]));
    expect(await File(extracted+'/verified-bundle.json').readAsString(),
      await File(scratch.path+'/sealed-native/verified-bundle.json')
        .readAsString());
  });

  test('missing or corrupted zip does not create an output directory',() async {
    final zip=await createZip();
    final raf=await File(zip).open(mode:FileMode.append);
    await raf.writeByte(42);
    await raf.close();
    await expectLater(ModMonthZipBundleV1
      .extractVerifiedIntoIsolatedDirectory(
        zipPath:zip,outputDirectory:scratch.path+'/never',
        isTopic:isTopic,transport:const _PythonZipTransport()),
      throwsA(isA<ModBundleInvalid>()));
    expect(await Directory(scratch.path+'/never').exists(),isFalse);
  });

  test('changed extracted image invalidates original sealed SHA and cleans up',
      () async {
    final zip=await createZip();
    await expectLater(ModMonthZipBundleV1
      .extractVerifiedIntoIsolatedDirectory(
        zipPath:zip,outputDirectory:scratch.path+'/not-published',
        isTopic:isTopic,transport:const _ModifyingTransport()),
      throwsA(isA<ModBundleInvalid>()));
    expect(await Directory(scratch.path+'/not-published').exists(),isFalse);
    expect(await File(scratch.path+'/sealed-native/media/image/photo.png')
      .readAsBytes(),orderedEquals([137,80,78,71,1,2,3]));
  });

  test('destination ZIP and extracted directory are never overwritten',
      () async {
    final source=await stage();
    final existing=File(scratch.path+'/old.zip');
    await existing.writeAsString('retain-me');
    await expectLater(ModMonthZipBundleV1.createVerified(
      sourceDirectory:source,outputZip:existing.path,
      isTopic:isTopic,transport:const _PythonZipTransport()),
      throwsA(isA<ModBundleInvalid>().having(
        (e)=>e.code,'code','target_already_exists')));
    expect(await existing.readAsString(),'retain-me');
    final zip=await ModMonthZipBundleV1.createVerified(
      sourceDirectory:source,outputZip:scratch.path+'/new.zip',
      isTopic:isTopic,transport:const _PythonZipTransport());
    final folder=Directory(scratch.path+'/existing-dir');
    await folder.create();
    final keep=File(folder.path+'/keep.txt');
    await keep.writeAsString('not-touched');
    await expectLater(ModMonthZipBundleV1
      .extractVerifiedIntoIsolatedDirectory(
        zipPath:zip,outputDirectory:folder.path,
        isTopic:isTopic,transport:const _PythonZipTransport()),
      throwsA(isA<ModBundleInvalid>().having(
        (e)=>e.code,'code','target_already_exists')));
    expect(await keep.readAsString(),'not-touched');
  });

  test('central directory refuses duplicate entries before extraction',() async {
    final zip=scratch.path+'/dupe.zip';
    await _PythonZipTransport.execute(['-c',r'''
import sys,zipfile
with zipfile.ZipFile(sys.argv[1],'w') as z:
    z.writestr('manifest.json','one')
    z.writestr('manifest.json','two')
    z.writestr('verified-bundle.json','{}')
    z.writestr('structured/month-graph.json','{}')
''',zip]);
    await expectLater(ModMonthZipPreflightV1.inspect(zip),
      throwsA(isA<ModBundleInvalid>().having(
        (e)=>e.code,'code','unsafe_or_duplicate_zip_entry')));
  });

  test('central directory refuses traversal, despite valid looking ZIP',
      () async {
    final zip=scratch.path+'/traversal.zip';
    await _PythonZipTransport.execute(['-c',r'''
import sys,zipfile
with zipfile.ZipFile(sys.argv[1],'w') as z:
    z.writestr('manifest.json','{}')
    z.writestr('verified-bundle.json','{}')
    z.writestr('structured/month-graph.json','{}')
    z.writestr('media/image/../../outside.png','bad')
''',zip]);
    await expectLater(ModMonthZipPreflightV1.inspect(zip),
      throwsA(isA<ModBundleInvalid>().having(
        (e)=>e.code,'code','unsafe_or_duplicate_zip_entry')));
  });

  test('central directory refuses symlink metadata',() async {
    final zip=scratch.path+'/symlink.zip';
    await _PythonZipTransport.execute(['-c',r'''
import sys,zipfile,stat
with zipfile.ZipFile(sys.argv[1],'w') as z:
    z.writestr('manifest.json','{}')
    z.writestr('verified-bundle.json','{}')
    z.writestr('structured/month-graph.json','{}')
    info=zipfile.ZipInfo('media/image/sneaky.png')
    info.create_system=3
    info.external_attr=(stat.S_IFLNK|0o777)<<16
    z.writestr(info,'/etc/passwd')
''',zip]);
    await expectLater(ModMonthZipPreflightV1.inspect(zip),
      throwsA(isA<ModBundleInvalid>().having(
        (e)=>e.code,'code','zip_special_file_not_allowed')));
  });

  test('compressed oversized metadata detected before any unzip',() async {
    final zip=scratch.path+'/bomb.zip';
    await _PythonZipTransport.execute(['-c',r'''
import sys,zipfile
with zipfile.ZipFile(sys.argv[1],'w',compression=zipfile.ZIP_DEFLATED) as z:
    z.writestr('verified-bundle.json','{}')
    z.writestr('structured/month-graph.json','{}')
    z.writestr('manifest.json',b'0'*(65*1024*1024))
''',zip]);
    await expectLater(ModMonthZipPreflightV1.inspect(zip),
      throwsA(isA<ModBundleInvalid>().having(
        (e)=>e.code,'code','zip_payload_quota_or_media_compression')));
  });

  test('unsupported encrypted ZIP and compressed media are rejected',
      () async {
    final zip=scratch.path+'/compressed-image.zip';
    await _PythonZipTransport.execute(['-c',r'''
import sys,zipfile
with zipfile.ZipFile(sys.argv[1],'w',compression=zipfile.ZIP_DEFLATED) as z:
    z.writestr('verified-bundle.json','{}')
    z.writestr('structured/month-graph.json','{}')
    z.writestr('manifest.json','{}')
    z.writestr('media/image/huge.png',b'0'*4096)
''',zip]);
    await expectLater(ModMonthZipPreflightV1.inspect(zip),
      throwsA(isA<ModBundleInvalid>().having(
        (e)=>e.code,'code','zip_payload_quota_or_media_compression')));
  });

  test('ZIP64 per-file sizes can be read without rejecting small archives',
      () async {
    final zip=scratch.path+'/zip64-entry.zip';
    await _PythonZipTransport.execute(['-c',r'''
import sys,zipfile
with zipfile.ZipFile(sys.argv[1],'w',allowZip64=True) as z:
    for name in ['verified-bundle.json','structured/month-graph.json','manifest.json']:
        info=zipfile.ZipInfo(name)
        with z.open(info,'w',force_zip64=True) as out:
            out.write(b'{}')
''',zip]);
    expect(await ModMonthZipPreflightV1.inspect(zip),containsAll([
      'verified-bundle.json','structured/month-graph.json','manifest.json',
    ]));
  });

  test('invalid ZIP never alters the existing native staging directory',
      () async {
    final zip=await createZip();
    final data=await File(scratch.path+'/sealed-native/verified-bundle.json')
        .readAsBytes();
    final truncated=File(scratch.path+'/truncated.zip');
    final source=await File(zip).readAsBytes();
    await truncated.writeAsBytes(source.sublist(0,source.length~/2));
    await expectLater(ModMonthZipBundleV1
      .extractVerifiedIntoIsolatedDirectory(
        zipPath:truncated.path,outputDirectory:scratch.path+'/untouched',
        isTopic:isTopic,transport:const _PythonZipTransport()),
      throwsA(isA<ModBundleInvalid>()));
    expect(await Directory(scratch.path+'/untouched').exists(),isFalse);
    expect(await File(scratch.path+'/sealed-native/verified-bundle.json')
      .readAsBytes(),orderedEquals(data));
  });
}
