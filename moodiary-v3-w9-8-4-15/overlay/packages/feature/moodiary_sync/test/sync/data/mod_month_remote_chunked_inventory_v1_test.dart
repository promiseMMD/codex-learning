import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:moodiary_sync/src/data/codec.dart';
import 'package:moodiary_sync/src/data/mod_month_remote_chunked_inventory_v1.dart';
import 'package:moodiary_sync/src/data/mod_month_remote_chunked_versions_v1.dart';
import 'package:moodiary_sync/src/data/mod_month_remote_versions_v1.dart';
import 'package:moodiary_sync/src/data/mod_month_webdav_resumable_v1.dart';
import '../sync_test_harness.dart';
import 'cloud_full_zip_fixture.dart';

final class _TestCipher extends SyncCipher {
  const _TestCipher():super.withKey(const [1,2,3,4]);
  @override
  Future<Uint8List> encryptBytes(Uint8List plain) async =>
    Uint8List.fromList([...utf8.encode(SyncCipher.magic),...plain.reversed]);
  @override
  Future<Uint8List> decryptBytes(Uint8List encrypted) async =>
    Uint8List.fromList(encrypted.sublist(SyncCipher.magic.length).reversed.toList());
}

void main(){
  const cipher=_TestCipher();
  const a='device-0001',b='device-0002';
  const root='snapshot-001',child='snapshot-002',sibling='snapshot-003';
  late Directory scratch;
  late CloudFullZipFixture fixture;
  setUp(() async {
    scratch=await Directory.systemTemp.createTemp('month-inventory-test-');
    fixture=await CloudFullZipFixture.create(scratch);
  });
  tearDown(() async {
    if(await scratch.exists())await scratch.delete(recursive:true);
  });

  Future<ModMonthChunkedReceipt> upload(FakeRemoteBackend backend) =>
    ModMonthWebdavResumableV1.upload(
      backend:backend,cipher:cipher,fullBackupZip:fixture.zip,
      chunkBytes:512,zipTransport:const CloudTestZipTransport());

  ModMonthRemoteVersionV1 descriptor(ModMonthChunkedReceipt receipt,{
    String owner=a,String id=root,String? parent,int time=1000,
    String? hash,
  })=>ModMonthRemoteVersionV1(
    deviceId:owner,snapshotId:id,parentSnapshotId:parent,
    archiveSha256:hash??receipt.archiveSha256,
    archiveBytes:receipt.archiveBytes,createdAtMs:time);

  Future<void> publish(FakeRemoteBackend cloud,ModMonthChunkedReceipt receipt,
      ModMonthRemoteVersionV1 version) async {
    await ModMonthRemoteChunkedVersionStoreV1.publish(
      backend:cloud,cipher:cipher,snapshot:version,receipt:receipt,
      zipTransport:const CloudTestZipTransport());
  }

  Future<void> writeDescriptor(FakeRemoteBackend cloud,
      ModMonthRemoteVersionV1 version) async {
    cloud.objects[ModMonthRemoteChunkedVersionStoreV1.keyFor(
      version.deviceId,version.snapshotId)]=await cipher.encryptBytes(
        Uint8List.fromList(utf8.encode(version.encode())));
  }

  Future<ModMonthChunkedInventoryV1> scan(FakeRemoteBackend cloud) =>
    ModMonthRemoteChunkedInventoryStoreV1.scan(
      backend:cloud,cipher:cipher);

  Future<File> export(FakeRemoteBackend cloud,String device,String id,
      String filename) =>
    ModMonthRemoteChunkedInventoryStoreV1.exportVerifiedSnapshot(
      backend:cloud,cipher:cipher,deviceId:device,snapshotId:id,
      destination:File(scratch.path+'/'+filename),
      zipTransport:const CloudTestZipTransport());

  test('empty catalog ignores unrelated and partial uploaded blobs',() async {
    final cloud=FakeRemoteBackend();
    cloud.objects['manifest.json']=Uint8List.fromList([1]);
    cloud.objects['mod-full-history/v1/resumable/chunks/abc.enc']=
      Uint8List.fromList([2]);
    final result=await scan(cloud);
    expect(result.versions,isEmpty);
    expect(result.deviceCount,0);
    expect(result.needsManualReview,false);
    expect(cloud.ops.where((op)=>op.startsWith('create ') ||
      op.startsWith('delete ') || op.startsWith('write ')),isEmpty);
  });

  test('lists canonical same-content two-device chains with stable heads',
      () async {
    final cloud=FakeRemoteBackend(),receipt=await upload(cloud);
    await publish(cloud,receipt,descriptor(receipt));
    await publish(cloud,receipt,descriptor(receipt,owner:b));
    await publish(cloud,receipt,descriptor(
      receipt,id:child,parent:root,time:2000));
    final before=cloud.objects.length;
    final report=await scan(cloud);
    expect(report.deviceCount,2);
    expect(report.versions,hasLength(3));
    expect(report.headsByDevice[a],[child]);
    expect(report.headsByDevice[b],[root]);
    expect(report.missingParents,isEmpty);
    expect(report.crossDeviceDivergence,false);
    expect(report.needsManualReview,false);
    expect(cloud.objects.length,before);
    expect(cloud.ops.where((x)=>x.startsWith('delete ')),isEmpty);
  });

  test('different archives across devices require explicit review',() async {
    final cloud=FakeRemoteBackend(),receipt=await upload(cloud);
    await publish(cloud,receipt,descriptor(receipt));
    await writeDescriptor(cloud,descriptor(receipt,owner:b,
      hash:List<String>.filled(64,'e').join()));
    final report=await scan(cloud);
    expect(report.crossDeviceDivergence,true);
    expect(report.needsManualReview,true);
    await expectLater(export(cloud,b,root,'unrecoverable.zip'),
      throwsA(isA<ModMonthChunkedError>().having(
        (e)=>e.code,'code','manifest_not_published')));
    expect(await File(scratch.path+'/unrecoverable.zip').exists(),false);
  });

  test('forked same-device heads and missing parents stay visible',() async {
    final cloud=FakeRemoteBackend(),receipt=await upload(cloud);
    await publish(cloud,receipt,descriptor(receipt));
    await publish(cloud,receipt,descriptor(receipt,
      id:child,parent:root,time:2000));
    await publish(cloud,receipt,descriptor(receipt,
      id:sibling,parent:root,time:2500));
    await writeDescriptor(cloud,descriptor(receipt,owner:b,
      id:child,parent:root,time:5000));
    final report=await scan(cloud);
    expect(report.headsByDevice[a],[child,sibling]);
    expect(report.missingParents,[b+'/'+child]);
    expect(report.needsManualReview,true);
  });

  test('invalid version paths and missing listed objects fail closed',() async {
    final cloud=FakeRemoteBackend();
    cloud.objects[ModMonthRemoteChunkedVersionStoreV1.prefix+
      'device-0001/../unsafe.json.enc']=Uint8List.fromList([1]);
    await expectLater(scan(cloud),throwsA(isA<ModMonthVersionError>()));
    cloud.objects.clear();
    final receipt=await upload(cloud);
    await publish(cloud,receipt,descriptor(receipt));
    final key=ModMonthRemoteChunkedVersionStoreV1.keyFor(a,root);
    cloud.beforeOp=(op,path){
      if(op=='read'&&path==key)cloud.objects.remove(path);
    };
    await expectLater(scan(cloud),throwsA(isA<ModMonthVersionError>()
      .having((e)=>e.code,'code','listed_version_missing')));
    expect(cloud.ops.where((x)=>x.startsWith('delete ')),isEmpty);
  });

  test('cycles and reverse time cannot pass chain review',() async {
    final cloud=FakeRemoteBackend(),receipt=await upload(cloud);
    await writeDescriptor(cloud,descriptor(receipt,
      id:root,parent:child,time:1000));
    await writeDescriptor(cloud,descriptor(receipt,
      id:child,parent:root,time:1000));
    await expectLater(scan(cloud),throwsA(isA<ModMonthVersionError>()
      .having((e)=>e.code,'code','version_cycle')));
    cloud.objects.clear();
    await writeDescriptor(cloud,descriptor(receipt,id:root,time:2000));
    await writeDescriptor(cloud,descriptor(receipt,
      id:child,parent:root,time:1000));
    await expectLater(scan(cloud),throwsA(isA<ModMonthVersionError>()
      .having((e)=>e.code,'code','nonmonotonic_version_time')));
  });

  test('verified export preserves current and deleted-revision media',() async {
    final cloud=FakeRemoteBackend(),receipt=await upload(cloud);
    await publish(cloud,receipt,descriptor(receipt));
    final result=await export(cloud,a,root,'snapshot.zip');
    expect(await result.readAsBytes(),
      orderedEquals(await fixture.zip.readAsBytes()));
    final folder=Directory(scratch.path+'/expanded');
    await folder.create();
    await const CloudTestZipTransport().extract(
      archivePath:result.path,destinationDirectory:folder.path);
    expect(await File(folder.path+'/'+CloudFullZipFixture.currentMedia)
      .readAsBytes(),orderedEquals(CloudFullZipFixture.currentBytes));
    expect(await File(folder.path+'/'+CloudFullZipFixture.historicalMedia)
      .readAsBytes(),orderedEquals(CloudFullZipFixture.historicalBytes));
  });

  test('failed readback never creates or replaces a local archive',() async {
    final cloud=FakeRemoteBackend(),receipt=await upload(cloud);
    await publish(cloud,receipt,descriptor(receipt));
    final existing=File(scratch.path+'/preserve.zip');
    await existing.writeAsString('existing data');
    await expectLater(export(cloud,a,root,'preserve.zip'),
      throwsA(isA<ModMonthVersionError>().having(
        (e)=>e.code,'code','destination_exists')));
    expect(await existing.readAsString(),'existing data');
    final chunk=cloud.objects.keys.firstWhere((k)=>k.contains('/chunks/'));
    cloud.objects.remove(chunk);
    await expectLater(export(cloud,a,root,'missing.zip'),
      throwsA(isA<ModMonthChunkedError>()
        .having((e)=>e.code,'code','chunk_missing')));
    expect(await File(scratch.path+'/missing.zip').exists(),false);
    expect(cloud.ops.where((x)=>x.startsWith('delete ')),isEmpty);
  });

  test('interrupted listing reports failure without partial success',() async {
    final cloud=FakeRemoteBackend(),receipt=await upload(cloud);
    await publish(cloud,receipt,descriptor(receipt));
    cloud.beforeOp=(op,key) {
      if(op=='list')throw const SocketException('network disconnected');
    };
    await expectLater(scan(cloud),throwsA(isA<SocketException>()));
    expect(cloud.ops.where((x)=>x.startsWith('write ') ||
      x.startsWith('delete ')),isEmpty);
  });
}
