import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:moodiary_sync/src/data/codec.dart';
import 'package:moodiary_sync/src/data/mod_month_remote_chunked_versions_v1.dart';
import 'package:moodiary_sync/src/data/mod_month_remote_versions_v1.dart';
import 'package:moodiary_sync/src/data/mod_month_webdav_resumable_v1.dart';

import '../sync_test_harness.dart';
import 'cloud_full_zip_fixture.dart';

final class _TestCipher extends SyncCipher {
  const _TestCipher() : super.withKey(const [1,2,3,4]);
  @override
  Future<Uint8List> encryptBytes(Uint8List bytes) async =>
      Uint8List.fromList([...utf8.encode(SyncCipher.magic),...bytes.reversed]);
  @override
  Future<Uint8List> decryptBytes(Uint8List bytes) async =>
      Uint8List.fromList(bytes.sublist(SyncCipher.magic.length).reversed.toList());
}

void main(){
  const cipher=_TestCipher();
  const deviceA='device-0001',deviceB='device-0002';
  const first='snapshot-001',second='snapshot-002';
  late Directory temp;
  late CloudFullZipFixture fixture;

  setUp(() async {
    temp=await Directory.systemTemp.createTemp('month-chunk-version-test-');
    fixture=await CloudFullZipFixture.create(temp);
  });
  tearDown(() async {
    if(await temp.exists())await temp.delete(recursive:true);
  });

  Future<ModMonthChunkedReceipt> upload(FakeRemoteBackend cloud) =>
    ModMonthWebdavResumableV1.upload(
      backend:cloud,cipher:cipher,fullBackupZip:fixture.zip,
      chunkBytes:512,zipTransport:const CloudTestZipTransport());

  ModMonthRemoteVersionV1 version(ModMonthChunkedReceipt receipt,{
    String owner=deviceA,String id=first,String? parent,int time=10000,
  }) => ModMonthRemoteVersionV1(
    deviceId:owner,snapshotId:id,parentSnapshotId:parent,
    archiveSha256:receipt.archiveSha256,
    archiveBytes:receipt.archiveBytes,createdAtMs:time);

  Future<bool> publish(FakeRemoteBackend cloud,
      ModMonthChunkedReceipt receipt,ModMonthRemoteVersionV1 snapshot) =>
    ModMonthRemoteChunkedVersionStoreV1.publish(
      backend:cloud,cipher:cipher,snapshot:snapshot,receipt:receipt,
      zipTransport:const CloudTestZipTransport());

  test('two-device immutable snapshot ledger and same-device parent chain',
      () async {
    final cloud=FakeRemoteBackend(),receipt=await upload(cloud);
    final a=version(receipt);
    final b=version(receipt,owner:deviceB);
    expect(await publish(cloud,receipt,a),false);
    expect(await publish(cloud,receipt,b),false);
    expect(await publish(cloud,receipt,
      version(receipt,id:second,parent:first)),false);
    final readBack=await ModMonthRemoteChunkedVersionStoreV1.read(
      backend:cloud,cipher:cipher,deviceId:deviceA,snapshotId:second);
    expect(readBack!.parentSnapshotId,first);
    expect(cloud.objects.containsKey('manifest.json'),false);
    expect(cloud.ops.where((op)=>op.startsWith('delete ')),isEmpty);
    expect(cloud.objects.keys.where((x)=>x.contains('/versions/')).length,3);
    final rec=await ModMonthWebdavResumableV1.downloadToNewFile(
      backend:cloud,cipher:cipher,archiveSha256:readBack.archiveSha256,
      destination:File(temp.path+'/verified-remote.zip'),
      zipTransport:const CloudTestZipTransport());
    expect(await rec.readAsBytes(),orderedEquals(await fixture.zip.readAsBytes()));
  });

  test('idempotent retry and same-device snapshot collision never overwrite',
      () async {
    final cloud=FakeRemoteBackend(),receipt=await upload(cloud);
    final snapshot=version(receipt);
    expect(await publish(cloud,receipt,snapshot),false);
    final key=ModMonthRemoteChunkedVersionStoreV1.keyFor(deviceA,first);
    final bytes=cloud.objects[key]!.toList();
    final creates=cloud.opCount('create');
    expect(await publish(cloud,receipt,snapshot),true);
    await expectLater(publish(cloud,receipt,version(receipt,time:10001)),
      throwsA(isA<ModMonthVersionError>().having(
        (e)=>e.code,'code','immutable_version_conflict')));
    expect(cloud.objects[key],orderedEquals(bytes));
    expect(cloud.opCount('create'),creates);
  });

  test('missing chunk or manifest prevents all version publication',
      () async {
    final cloud=FakeRemoteBackend(),receipt=await upload(cloud);
    final key=cloud.objects.keys.firstWhere((x)=>x.contains('/chunks/'));
    final saved=cloud.objects.remove(key)!;
    await expectLater(publish(cloud,receipt,version(receipt)),
      throwsA(isA<ModMonthChunkedError>().having(
        (e)=>e.code,'code','chunk_missing')));
    expect(cloud.objects.keys.where((x)=>x.contains('/versions/')),isEmpty);
    cloud.objects[key]=saved;
    cloud.objects.remove(
      ModMonthWebdavResumableV1.manifestKey(receipt.archiveSha256));
    await expectLater(publish(cloud,receipt,version(receipt)),
      throwsA(isA<ModMonthChunkedError>().having(
        (e)=>e.code,'code','manifest_not_published')));
    expect(cloud.objects.keys.where((x)=>x.contains('/versions/')),isEmpty);
  });

  test('forged receipt and missing parent fail before writing a version',
      () async {
    final cloud=FakeRemoteBackend(),receipt=await upload(cloud);
    final falseReceipt=ModMonthChunkedReceipt(
      archiveSha256:receipt.archiveSha256,
      archiveBytes:receipt.archiveBytes+1,
      chunkCount:receipt.chunkCount,
      reusedChunks:receipt.reusedChunks,
      manifestReused:receipt.manifestReused);
    await expectLater(publish(cloud,falseReceipt,version(receipt)),
      throwsA(isA<ModMonthVersionError>().having(
        (e)=>e.code,'code','chunked_archive_receipt_mismatch')));
    await expectLater(publish(cloud,receipt,
      version(receipt,id:second,parent:first)),
      throwsA(isA<ModMonthVersionError>().having(
        (e)=>e.code,'code','parent_not_published')));
    expect(cloud.objects.keys.where((x)=>x.contains('/versions/')),isEmpty);
  });

  test('unsupported conditional creation never announces a snapshot',
      () async {
    final cloud=FakeRemoteBackend(),receipt=await upload(cloud);
    cloud.conditionalPutSupported=false;
    await expectLater(publish(cloud,receipt,version(receipt)),
      throwsA(isA<ModMonthVersionError>().having(
        (e)=>e.code,'code','exclusive_creation_unsupported')));
    expect(cloud.objects.keys.where((x)=>x.contains('/versions/')),isEmpty);
  });

  test('network interruption before manifest then resumed upload and publish',
      () async {
    final cloud=FakeRemoteBackend();
    var created=0;
    cloud.beforeOp=(op,key){
      if(op=='create' && key.contains('/chunks/')){
        created++;
        if(created==2)throw const SocketException('network failed');
      }
    };
    await expectLater(upload(cloud),throwsA(isA<SocketException>()));
    expect(cloud.objects.keys.where((k)=>k.contains('/versions/')),isEmpty);
    expect(cloud.objects.keys.where((k)=>k.contains('/manifests/')),isEmpty);
    cloud.beforeOp=null;
    final receipt=await upload(cloud);
    expect(receipt.reusedChunks,greaterThan(0));
    expect(await publish(cloud,receipt,version(receipt)),false);
    final recovered=await ModMonthRemoteChunkedVersionStoreV1.read(
      backend:cloud,cipher:cipher,deviceId:deviceA,snapshotId:first);
    expect(recovered!.archiveSha256,receipt.archiveSha256);
  });

  test('damaged encrypted descriptor fails without overwrite',() async {
    final cloud=FakeRemoteBackend(),receipt=await upload(cloud);
    await publish(cloud,receipt,version(receipt));
    final key=ModMonthRemoteChunkedVersionStoreV1.keyFor(deviceA,first);
    cloud.objects[key]=Uint8List.fromList(utf8.encode(version(receipt).encode()));
    await expectLater(ModMonthRemoteChunkedVersionStoreV1.read(
      backend:cloud,cipher:cipher,deviceId:deviceA,snapshotId:first),
      throwsA(isA<ModMonthVersionError>().having(
        (e)=>e.code,'code','invalid_encrypted_version')));
  });
}
