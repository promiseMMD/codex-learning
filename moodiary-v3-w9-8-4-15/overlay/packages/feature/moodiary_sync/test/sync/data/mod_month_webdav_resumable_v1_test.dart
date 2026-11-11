import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:moodiary_sync/src/data/codec.dart';
import 'package:moodiary_sync/src/data/mod_month_webdav_resumable_v1.dart';

import '../sync_test_harness.dart';
import 'cloud_full_zip_fixture.dart';

/// Reversible test double. Production uses authenticated SyncCipher AES.
final class _TestEncryptedCipher extends SyncCipher {
  const _TestEncryptedCipher() : super.withKey(const [1,2,3,4]);

  @override
  Future<Uint8List> encryptBytes(Uint8List data) async =>
      Uint8List.fromList([
        ...utf8.encode(SyncCipher.magic), ...data.reversed,
      ]);

  @override
  Future<Uint8List> decryptBytes(Uint8List encrypted) async {
    final prefix=utf8.encode(SyncCipher.magic);
    if(encrypted.length<=prefix.length ||
        utf8.decode(encrypted.sublist(0,prefix.length))
            !=SyncCipher.magic){
      throw const FormatException('invalid encrypted test chunk');
    }
    return Uint8List.fromList(
      encrypted.sublist(prefix.length).reversed.toList());
  }
}

void main() {
  const cipher=_TestEncryptedCipher();
  const chunkBytes=512;
  late Directory scratch;
  late CloudFullZipFixture fixture;

  setUp(() async {
    scratch=await Directory.systemTemp.createTemp('month-resumable-test-');
    fixture=await CloudFullZipFixture.create(scratch);
  });

  tearDown(() async {
    if(await scratch.exists())await scratch.delete(recursive:true);
  });

  Future<ModMonthChunkedReceipt> upload(FakeRemoteBackend remote) =>
    ModMonthWebdavResumableV1.upload(
      backend:remote,cipher:cipher,fullBackupZip:fixture.zip,
      zipTransport:const CloudTestZipTransport(),chunkBytes:chunkBytes);

  Future<File> download(FakeRemoteBackend remote,String hash,String name) =>
    ModMonthWebdavResumableV1.downloadToNewFile(
      backend:remote,cipher:cipher,archiveSha256:hash,
      destination:File(scratch.path+'/'+name),
      zipTransport:const CloudTestZipTransport());

  test('publishes manifest LAST; verifies both live and deleted-revision media',
      () async {
    final remote=FakeRemoteBackend();
    final receipt=await upload(remote);
    expect(receipt.chunkCount,greaterThan(1));
    final manifestKey=ModMonthWebdavResumableV1.manifestKey(
      receipt.archiveSha256);
    final writes=remote.ops.where((op)=>op.startsWith('create ')).toList();
    expect(writes.last,'create '+manifestKey);
    expect(remote.objects.containsKey('manifest.json'),false);
    expect(remote.ops.where((op)=>op.startsWith('delete ')),isEmpty);
    expect(remote.objects[manifestKey],isNotNull);
    expect(SyncCipher.isCipherText(remote.objects[manifestKey]!),true);

    final restored=await download(remote,receipt.archiveSha256,'verified.zip');
    expect(await restored.readAsBytes(),
      orderedEquals(await fixture.zip.readAsBytes()));

    final out=Directory(scratch.path+'/unpacked');
    await out.create();
    await const CloudTestZipTransport().extract(
      archivePath:restored.path,destinationDirectory:out.path);
    expect(await File(out.path+'/'+CloudFullZipFixture.currentMedia)
      .readAsBytes(),orderedEquals(CloudFullZipFixture.currentBytes));
    expect(await File(out.path+'/'+CloudFullZipFixture.historicalMedia)
      .readAsBytes(),orderedEquals(CloudFullZipFixture.historicalBytes));
  });

  test('network interruption leaves no committed manifest; retry reuses chunks',
      () async {
    final remote=FakeRemoteBackend();
    var count=0;
    remote.beforeOp=(op,key) {
      if(op=='create' && key.contains('/chunks/')) {
        count++;
        if(count==2)throw const SocketException('interrupted after first chunk');
      }
    };
    await expectLater(upload(remote),throwsA(isA<SocketException>()));
    final existing=remote.objects.keys.where((k)=>k.contains('/chunks/'))
      .toList();
    expect(existing,isNotEmpty);
    expect(remote.objects.keys.where((k)=>k.contains('/manifests/')),isEmpty);
    final firstBytes=remote.objects[existing.first]!.toList();
    remote.beforeOp=null;
    final receipt=await upload(remote);
    expect(receipt.reusedChunks,greaterThanOrEqualTo(1));
    expect(remote.objects[existing.first],orderedEquals(firstBytes));
    expect(remote.objects.containsKey(ModMonthWebdavResumableV1.manifestKey(
      receipt.archiveSha256)),true);
    final restored=await download(remote,receipt.archiveSha256,'after-retry.zip');
    expect(await restored.readAsBytes(),
      orderedEquals(await fixture.zip.readAsBytes()));
  });

  test('idempotent retry never overwrites chunks or manifest',() async {
    final remote=FakeRemoteBackend();
    final first=await upload(remote);
    final before=remote.opCount('create');
    final snapshot={
      for(final entry in remote.objects.entries)
        entry.key:entry.value.toList(),
    };
    final second=await upload(remote);
    expect(second.archiveSha256,first.archiveSha256);
    expect(second.reusedChunks,second.chunkCount);
    expect(second.manifestReused,true);
    expect(remote.opCount('create'),before);
    for(final entry in snapshot.entries){
      expect(remote.objects[entry.key],orderedEquals(entry.value));
    }
  });

  test('corrupt existing encrypted chunk is not overwritten by retry',
      () async {
    final remote=FakeRemoteBackend();
    final receipt=await upload(remote);
    final key=remote.objects.keys.firstWhere((k)=>k.contains('/chunks/'));
    remote.objects[key]=Uint8List.fromList([1,2,3,4]);
    final before=remote.opCount('create');
    final target=File(scratch.path+'/should-not-appear.zip');
    await expectLater(
      ModMonthWebdavResumableV1.downloadToNewFile(
        backend:remote,cipher:cipher,
        archiveSha256:receipt.archiveSha256,destination:target,
        zipTransport:const CloudTestZipTransport()),
      throwsA(isA<ModMonthChunkedError>().having(
        (e)=>e.code,'code','chunk_not_encrypted')));
    expect(await target.exists(),false);
    await expectLater(upload(remote),throwsA(isA<ModMonthChunkedError>()));
    expect(remote.opCount('create'),before);
    expect(remote.objects[key],orderedEquals([1,2,3,4]));
  });

  test('interrupted download never creates destination; retry completes',
      () async {
    final remote=FakeRemoteBackend();
    final receipt=await upload(remote);
    var count=0;
    remote.beforeOp=(op,key){
      if(op=='read' && key.contains('/chunks/')) {
        count++;
        if(count==2)throw const SocketException('offline during download');
      }
    };
    final target=File(scratch.path+'/download-interrupted.zip');
    await expectLater(
      ModMonthWebdavResumableV1.downloadToNewFile(
        backend:remote,cipher:cipher,
        archiveSha256:receipt.archiveSha256,destination:target,
        zipTransport:const CloudTestZipTransport()),
      throwsA(isA<SocketException>()));
    expect(await target.exists(),false);
    remote.beforeOp=null;
    await download(remote,receipt.archiveSha256,'download-interrupted.zip');
    expect(await target.readAsBytes(),
      orderedEquals(await fixture.zip.readAsBytes()));
  });

  test('missing manifest is never treated as backup success',() async {
    final remote=FakeRemoteBackend();
    final before=await fixture.zip.readAsBytes();
    await expectLater(download(remote,List<String>.filled(64,'a').join(),'no-manifest.zip'),
      throwsA(isA<ModMonthChunkedError>().having(
        (e)=>e.code,'code','manifest_not_published')));
    expect(await File(scratch.path+'/no-manifest.zip').exists(),false);
    expect(await fixture.zip.readAsBytes(),orderedEquals(before));
    expect(remote.ops.where((op)=>op.startsWith('delete ')),isEmpty);
  });

  test('server without conditional creation refuses to publish',() async {
    final remote=FakeRemoteBackend()..conditionalPutSupported=false;
    await expectLater(upload(remote),
      throwsA(isA<ModMonthChunkedError>().having(
        (e)=>e.code,'code','conditional_create_unsupported')));
    expect(remote.objects,isEmpty);
    expect(remote.ops.where((op)=>op.startsWith('delete ')),isEmpty);
  });

  test('historical media altered or missing is rejected BEFORE chunk upload',
      () async {
    final remote=FakeRemoteBackend();
    for(final missing in [false,true]){
      final damaged=await fixture.changedHistoricalMedia(
        scratch.path+'/damaged-'+(missing?'missing':'changed')+'.zip',
        remove:missing);
      await expectLater(ModMonthWebdavResumableV1.upload(
        backend:remote,cipher:cipher,fullBackupZip:damaged,
        zipTransport:const CloudTestZipTransport(),chunkBytes:chunkBytes),
        throwsA(anything));
    }
    expect(remote.ops,isEmpty);
  });

  test('already existing user backup is not overwritten',() async {
    final remote=FakeRemoteBackend();
    final receipt=await upload(remote);
    final existing=File(scratch.path+'/keep-original.zip');
    await existing.writeAsString('existing valuable data');
    final prior=await existing.readAsBytes();
    await expectLater(
      ModMonthWebdavResumableV1.downloadToNewFile(
        backend:remote,cipher:cipher,
        archiveSha256:receipt.archiveSha256,destination:existing,
        zipTransport:const CloudTestZipTransport()),
      throwsA(isA<ModMonthChunkedError>().having(
        (e)=>e.code,'code','destination_exists')));
    expect(await existing.readAsBytes(),orderedEquals(prior));
  });
}
