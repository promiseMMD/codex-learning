import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:moodiary_sync/src/data/codec.dart';
import 'package:moodiary_sync/src/data/mod_month_webdav_full_zip_v1.dart';
import 'package:moodiary_sync/src/data/mod_month_remote_versions_v1.dart';
import '../sync_test_harness.dart';

final class _TestCipher extends SyncCipher {
  const _TestCipher() : super.withKey(const [1,2,3,4]);
  @override
  Future<Uint8List> encryptBytes(Uint8List input) async =>
      Uint8List.fromList([...utf8.encode(SyncCipher.magic),...input.reversed]);
  @override
  Future<Uint8List> decryptBytes(Uint8List input) async =>
      Uint8List.fromList(input.sublist(SyncCipher.magic.length).reversed.toList());
  @override
  Future<void> encryptFileTo(String src,String dst) async {
    await File(dst).writeAsBytes(await encryptBytes(
      Uint8List.fromList(await File(src).readAsBytes())));
  }
  @override
  Future<void> decryptFileTo(String src,String dst) async {
    await File(dst).writeAsBytes(await decryptBytes(
      Uint8List.fromList(await File(src).readAsBytes())));
  }
}

Future<File> fixture(String path) async {
  final run=await Process.run('python3',['-c',r'''
import sys,zipfile
with zipfile.ZipFile(sys.argv[1],'w') as z:
  for name in ['manifest.json','verified-day-bundle-v2.json',
               'structured/month-day-graph-v2.json']:
    z.writestr(name,'{"transport":"test"}')
''',path]);
  if (run.exitCode!=0) throw StateError(run.stderr.toString());
  return File(path);
}

void main() {
  const cipher=_TestCipher();
  const device='device-0001',other='device-0002';
  const first='snapshot-001',second='snapshot-002';
  late Directory dir;
  late File zip;
  setUp(() async {
    dir=await Directory.systemTemp.createTemp('month-ver-test-');
    zip=await fixture(dir.path+'/source.zip');
  });
  tearDown(() async {
    if(await dir.exists())await dir.delete(recursive:true);
  });

  ModMonthRemoteVersionV1 ver(ModMonthWebdavZipReceipt r,{
    String owner=device,String snap=first,String? parent,int at=10000,
  }) => ModMonthRemoteVersionV1(
    deviceId:owner,snapshotId:snap,parentSnapshotId:parent,
    archiveSha256:r.sha256,archiveBytes:r.bytes,createdAtMs:at);

  Future<ModMonthWebdavZipReceipt> upload(FakeRemoteBackend cloud) =>
    ModMonthWebdavFullZipV1.upload(
      backend:cloud,cipher:cipher,fullBackupZip:zip);

  test('same device parent chain is immutable and duplicate is a no-op',
      () async {
    final cloud=FakeRemoteBackend(),r=await upload(cloud);
    final root=ver(r);
    expect(await ModMonthRemoteVersionStoreV1.publish(
      backend:cloud,cipher:cipher,snapshot:root,receipt:r),false);
    expect(await ModMonthRemoteVersionStoreV1.publish(
      backend:cloud,cipher:cipher,snapshot:root,receipt:r),true);
    final child=ver(r,snap:second,parent:first);
    await ModMonthRemoteVersionStoreV1.publish(
      backend:cloud,cipher:cipher,snapshot:child,receipt:r);
    final item=await ModMonthRemoteVersionStoreV1.read(
      backend:cloud,cipher:cipher,deviceId:device,snapshotId:second);
    expect(item!.parentSnapshotId,first);
    expect(cloud.opCount('create'),2);
    expect(cloud.objects.containsKey('manifest.json'),false);
    expect(cloud.ops.where((op)=>op.startsWith('delete ')),isEmpty);
  });

  test('two devices can create same snapshot ID without collisions',() async {
    final cloud=FakeRemoteBackend(),r=await upload(cloud);
    for(final id in [device,other]) {
      await ModMonthRemoteVersionStoreV1.publish(
        backend:cloud,cipher:cipher,snapshot:ver(r,owner:id),receipt:r);
    }
    expect(cloud.objects.containsKey(
      ModMonthRemoteVersionStoreV1.keyFor(device,first)),true);
    expect(cloud.objects.containsKey(
      ModMonthRemoteVersionStoreV1.keyFor(other,first)),true);
  });

  test('same device snapshot cannot overwrite different data',() async {
    final cloud=FakeRemoteBackend(),r=await upload(cloud);
    await ModMonthRemoteVersionStoreV1.publish(
      backend:cloud,cipher:cipher,snapshot:ver(r),receipt:r);
    final key=ModMonthRemoteVersionStoreV1.keyFor(device,first);
    final before=cloud.objects[key]!.toList(),writes=cloud.opCount('create');
    await expectLater(ModMonthRemoteVersionStoreV1.publish(
      backend:cloud,cipher:cipher,snapshot:ver(r,at:10001),receipt:r),
      throwsA(isA<ModMonthVersionError>().having(
        (e)=>e.code,'code','immutable_version_conflict')));
    expect(cloud.objects[key],orderedEquals(before));
    expect(cloud.opCount('create'),writes);
  });

  test('missing parent and unsupported CAS prevent any version creation',
      () async {
    final cloud=FakeRemoteBackend(),r=await upload(cloud);
    await expectLater(ModMonthRemoteVersionStoreV1.publish(
      backend:cloud,cipher:cipher,
      snapshot:ver(r,snap:second,parent:first),receipt:r),
      throwsA(isA<ModMonthVersionError>().having(
        (e)=>e.code,'code','parent_not_published')));
    cloud.conditionalPutSupported=false;
    await expectLater(ModMonthRemoteVersionStoreV1.publish(
      backend:cloud,cipher:cipher,snapshot:ver(r),receipt:r),
      throwsA(isA<ModMonthVersionError>().having(
        (e)=>e.code,'code','exclusive_creation_unsupported')));
    expect(cloud.opCount('write'),1);
    expect(cloud.objects.keys,contains(r.remoteKey));
  });

  test('missing remote ZIP and tampered descriptor fail closed',() async {
    final cloud=FakeRemoteBackend(),r=await upload(cloud);
    cloud.objects.remove(r.remoteKey);
    await expectLater(ModMonthRemoteVersionStoreV1.publish(
      backend:cloud,cipher:cipher,snapshot:ver(r),receipt:r),
      throwsA(isA<ModMonthWebdavZipException>()));
    expect(cloud.opCount('create'),0);
    final key=ModMonthRemoteVersionStoreV1.keyFor(device,first);
    cloud.objects[key]=Uint8List.fromList(
      utf8.encode(ver(r).encode()));
    await expectLater(ModMonthRemoteVersionStoreV1.read(
      backend:cloud,cipher:cipher,deviceId:device,snapshotId:first),
      throwsA(isA<ModMonthVersionError>().having(
        (e)=>e.code,'code','invalid_encrypted_version')));
  });

  test('unsafe paths and invalid version shapes rejected',() {
    expect(()=>ModMonthRemoteVersionStoreV1.keyFor('../',first),
      throwsA(isA<ModMonthVersionError>()));
    expect(()=>ModMonthRemoteVersionStoreV1.keyFor(device,'bad/path'),
      throwsA(isA<ModMonthVersionError>()));
    expect(()=>ModMonthRemoteVersionV1.decode('{"format":"bad"}'),
      throwsA(isA<ModMonthVersionError>()));
  });
}
