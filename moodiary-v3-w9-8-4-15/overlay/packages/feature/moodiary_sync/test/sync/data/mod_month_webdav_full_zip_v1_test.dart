import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:moodiary_sync/src/data/codec.dart';
import 'package:moodiary_sync/src/data/mod_month_webdav_full_zip_v1.dart';

import '../sync_test_harness.dart';
import 'cloud_full_zip_fixture.dart';

// Fake reversible file codec for the test host without native crypto assets.
// Production always calls SyncCipher's authenticated AES implementation.
final class _FakeEncryptedCipher extends SyncCipher {
  const _FakeEncryptedCipher() : super.withKey(const [1,2,3,4]);

  @override
  Future<void> encryptFileTo(String from,String to) async {
    final input=await File(from).readAsBytes();
    await File(to).writeAsBytes([
      ...utf8.encode(SyncCipher.magic),...input.reversed,
    ]);
  }

  @override
  Future<void> decryptFileTo(String from,String to) async {
    final input=await File(from).readAsBytes();
    final header=utf8.encode(SyncCipher.magic);
    if(input.length<=header.length ||
       utf8.decode(input.sublist(0,header.length))!=SyncCipher.magic) {
      throw const FormatException('invalid fixture cipher');
    }
    await File(to).writeAsBytes(input.sublist(header.length).reversed.toList());
  }
}


void main() {
  late Directory temp;
  late File zip;
  late CloudFullZipFixture fixture;
  setUp(() async {
    temp=await Directory.systemTemp.createTemp('moodiary-webdav-v1-test-');
    fixture=await CloudFullZipFixture.create(temp);
    zip=fixture.zip;
  });
  tearDown(() async {
    if(await temp.exists())await temp.delete(recursive:true);
  });

  test('encrypted ZIP round trip, legacy manifest unchanged',() async {
    final remote=FakeRemoteBackend();
    const cipher=_FakeEncryptedCipher();
    final original=await zip.readAsBytes();
    final receipt=await ModMonthWebdavFullZipV1.upload(
      backend:remote,cipher:cipher,fullBackupZip:zip,
      zipTransport:const CloudTestZipTransport());
    expect(receipt.reused,isFalse);
    expect(receipt.remoteKey,startsWith(ModMonthWebdavFullZipV1.prefix));
    expect(receipt.remoteKey,endsWith('.zip.enc'));
    expect(remote.objects.containsKey('manifest.json'),isFalse);
    expect(remote.ops.where((op)=>op.startsWith('delete ')),isEmpty);
    expect(await zip.readAsBytes(),orderedEquals(original));
    final encrypted=remote.objects[receipt.remoteKey]!;
    expect(encrypted,isNot(orderedEquals(original)));
    expect(utf8.decode(encrypted.sublist(0,SyncCipher.magic.length)),
      SyncCipher.magic);
    final target=File(temp.path+'/fresh-restored.zip');
    final output=await ModMonthWebdavFullZipV1.downloadToNewFile(
      backend:remote,cipher:cipher,sha256:receipt.sha256,destination:target,
      zipTransport:const CloudTestZipTransport());
    expect(output.path,target.path);
    expect(await output.readAsBytes(),orderedEquals(original));
    expect(remote.objects.keys,unorderedEquals([receipt.remoteKey]));
  });

  test('verified object is reused; never overwritten on retry',() async {
    final remote=FakeRemoteBackend();
    const cipher=_FakeEncryptedCipher();
    final a=await ModMonthWebdavFullZipV1.upload(
      backend:remote,cipher:cipher,fullBackupZip:zip,
      zipTransport:const CloudTestZipTransport());
    final writes=remote.opCount('write');
    final b=await ModMonthWebdavFullZipV1.upload(
      backend:remote,cipher:cipher,fullBackupZip:zip,
      zipTransport:const CloudTestZipTransport());
    expect(b.reused,isTrue);
    expect(b.remoteKey,a.remoteKey);
    expect(remote.opCount('write'),writes);
  });

  test('corrupted remote object causes refusal without overwrite',() async {
    final remote=FakeRemoteBackend();
    const cipher=_FakeEncryptedCipher();
    final receipt=await ModMonthWebdavFullZipV1.upload(
      backend:remote,cipher:cipher,fullBackupZip:zip,
      zipTransport:const CloudTestZipTransport());
    remote.objects[receipt.remoteKey]=Uint8List.fromList([1,2,3,4]);
    final writes=remote.opCount('write');
    await expectLater(ModMonthWebdavFullZipV1.upload(
      backend:remote,cipher:cipher,fullBackupZip:zip,
      zipTransport:const CloudTestZipTransport()),
      throwsA(isA<ModMonthWebdavZipException>().having(
        (e)=>e.code,'code','remote_not_encrypted')));
    expect(remote.opCount('write'),writes);
    final target=File(temp.path+'/missing.zip');
    await expectLater(ModMonthWebdavFullZipV1.downloadToNewFile(
      backend:remote,cipher:cipher,sha256:receipt.sha256,destination:target,
      zipTransport:const CloudTestZipTransport()),
      throwsA(isA<ModMonthWebdavZipException>()));
    expect(await target.exists(),isFalse);
  });

  test('plaintext and invalid ZIP fail without any remote mutation',() async {
    final remote=FakeRemoteBackend();
    await expectLater(ModMonthWebdavFullZipV1.upload(
      backend:remote,cipher:SyncCipher.plaintext,fullBackupZip:zip,
      zipTransport:const CloudTestZipTransport()),
      throwsA(isA<ModMonthWebdavZipException>().having(
        (e)=>e.code,'code','encryption_required')));
    final bad=File(temp.path+'/bad.zip');
    await bad.writeAsString('not a ZIP');
    await expectLater(ModMonthWebdavFullZipV1.upload(
      backend:remote,cipher:const _FakeEncryptedCipher(),fullBackupZip:bad,
      zipTransport:const CloudTestZipTransport()),
      throwsA(anything));
    expect(remote.ops,isEmpty);
  });

  test('existing user destination remains unmodified',() async {
    final remote=FakeRemoteBackend();
    const cipher=_FakeEncryptedCipher();
    final receipt=await ModMonthWebdavFullZipV1.upload(
      backend:remote,cipher:cipher,fullBackupZip:zip,
      zipTransport:const CloudTestZipTransport());
    final target=File(temp.path+'/important.zip');
    await target.writeAsString('existing user data');
    final before=await target.readAsBytes();
    final count=remote.ops.length;
    await expectLater(ModMonthWebdavFullZipV1.downloadToNewFile(
      backend:remote,cipher:cipher,sha256:receipt.sha256,destination:target,
      zipTransport:const CloudTestZipTransport()),
      throwsA(isA<ModMonthWebdavZipException>().having(
        (e)=>e.code,'code','destination_exists')));
    expect(remote.ops.length,count);
    expect(await target.readAsBytes(),orderedEquals(before));
  });

  test('network failure never deletes local ZIP or remote content',() async {
    final remote=FakeRemoteBackend();
    remote.beforeOp=(op,key) {
      if(op=='write')throw const SocketException('interrupted upload');
    };
    final before=await zip.readAsBytes();
    await expectLater(ModMonthWebdavFullZipV1.upload(
      backend:remote,cipher:const _FakeEncryptedCipher(),fullBackupZip:zip,
      zipTransport:const CloudTestZipTransport()),
      throwsA(isA<SocketException>()));
    expect(await zip.readAsBytes(),orderedEquals(before));
    expect(remote.objects,isEmpty);
    expect(remote.ops.where((op)=>op.startsWith('delete ')),isEmpty);
  });

  test('changed or missing deleted-revision image rejected before WebDAV upload',
      () async {
    final remote=FakeRemoteBackend();
    const cipher=_FakeEncryptedCipher();
    for(final missing in [false,true]) {
      final damaged=await fixture.changedHistoricalMedia(
        temp.path+'/bad-'+(missing?'missing':'changed')+'.zip',
        remove:missing);
      await expectLater(ModMonthWebdavFullZipV1.upload(
        backend:remote,cipher:cipher,fullBackupZip:damaged,
        zipTransport:const CloudTestZipTransport()),
        throwsA(anything));
    }
    expect(remote.ops,isEmpty);
  });

  test('remote round trip keeps current and deleted-revision images',
      () async {
    final remote=FakeRemoteBackend();
    const cipher=_FakeEncryptedCipher();
    final receipt=await ModMonthWebdavFullZipV1.upload(
      backend:remote,cipher:cipher,fullBackupZip:zip,
      zipTransport:const CloudTestZipTransport());
    final restored=File(temp.path+'/roundtrip.zip');
    await ModMonthWebdavFullZipV1.downloadToNewFile(
      backend:remote,cipher:cipher,sha256:receipt.sha256,
      destination:restored,zipTransport:const CloudTestZipTransport());
    final output=Directory(temp.path+'/unpacked');
    await output.create();
    await const CloudTestZipTransport().extract(
      archivePath:restored.path,destinationDirectory:output.path);
    expect(await File(output.path+'/'+CloudFullZipFixture.currentMedia)
      .readAsBytes(),orderedEquals(CloudFullZipFixture.currentBytes));
    expect(await File(output.path+'/'+CloudFullZipFixture.historicalMedia)
      .readAsBytes(),orderedEquals(CloudFullZipFixture.historicalBytes));
  });

}
