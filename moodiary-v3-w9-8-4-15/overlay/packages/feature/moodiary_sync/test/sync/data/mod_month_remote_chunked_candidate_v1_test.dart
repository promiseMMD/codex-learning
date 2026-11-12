import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:moodiary_sync/src/data/codec.dart';
import 'package:moodiary_sync/src/data/mod_month_remote_chunked_candidate_v1.dart';
import 'package:moodiary_sync/src/data/mod_month_remote_chunked_versions_v1.dart';
import 'package:moodiary_sync/src/data/mod_month_remote_versions_v1.dart';
import 'package:moodiary_sync/src/data/mod_month_webdav_resumable_v1.dart';
import 'package:moodiary_sync/src/data/mod_month_full_backup_archive_v1.dart';
import 'package:moodiary_sync/src/data/mod_month_verified_manifest_v2.dart';
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

void main() {
  const cipher=_TestCipher();
  const a='device-0001',b='device-0002',snapshot='snapshot-0001';
  late Directory temp;

  setUp(() async {
    temp=await Directory.systemTemp.createTemp('month-candidate-test-');
  });
  tearDown(() async {
    if(await temp.exists())await temp.delete(recursive:true);
  });

  Future<CloudFullZipFixture> fixture(String label,{
    bool includeChild=true,
    bool deleted=true,
    String childId='cloud-history-revision-0002',
    String? childImageName,
    String nativeTitle='cloud backup',
    List<int>? historic,
  }) async {
    final dir=Directory(temp.path+'/'+label);
    await dir.create();
    return CloudFullZipFixture.create(dir,
      includeChild:includeChild,
      childRevisionId:childId,
      childDeleted:deleted,
      childImageName:childImageName,
      nativeTitle:nativeTitle,
      historicalMediaBytes:historic);
  }

  Future<ModMonthChunkedReceipt> upload(FakeRemoteBackend cloud,
      CloudFullZipFixture input) =>
    ModMonthWebdavResumableV1.upload(
      backend:cloud,cipher:cipher,fullBackupZip:input.zip,
      chunkBytes:512,zipTransport:const CloudTestZipTransport());

  Future<void> publish(FakeRemoteBackend cloud,
      ModMonthChunkedReceipt receipt,String owner) async {
    await ModMonthRemoteChunkedVersionStoreV1.publish(
      backend:cloud,cipher:cipher,
      snapshot:ModMonthRemoteVersionV1(
        deviceId:owner,snapshotId:snapshot,parentSnapshotId:null,
        archiveSha256:receipt.archiveSha256,
        archiveBytes:receipt.archiveBytes,createdAtMs:1000),
      receipt:receipt,zipTransport:const CloudTestZipTransport());
  }

  Future<ModMonthCandidateReceiptV1> build(
      FakeRemoteBackend cloud,String output) =>
    ModMonthRemoteChunkedCandidateV1.build(
      backend:cloud,cipher:cipher,
      leftDeviceId:a,leftSnapshotId:snapshot,
      rightDeviceId:b,rightSnapshotId:snapshot,
      destination:File(temp.path+'/'+output),
      zipTransport:const CloudTestZipTransport());

  test('ancestor and descendant histories create a full verified ZIP with '
      'all revision and media bytes, without WebDAV writes',() async {
    final cloud=FakeRemoteBackend();
    final left=await fixture('ancestor',includeChild:false);
    final right=await fixture('descendant',deleted:false,
      childImageName:'new-photo.png');
    await publish(cloud,await upload(cloud,left),a);
    await publish(cloud,await upload(cloud,right),b);
    final writes=cloud.ops.where((op)=>op.startsWith('write ') ||
      op.startsWith('create ') || op.startsWith('delete ')).length;

    final candidate=await build(cloud,'candidate.zip');
    // Publication must not leave a staging directory behind. A crash may
    // leave staging bytes, but must never expose an incomplete final ZIP.
    final remaining=await temp.list().map((entry)=>
      entry.path.split(Platform.pathSeparator).last).toList();
    expect(remaining.where((name)=>name.startsWith('.moodiary-candidate-')),
      isEmpty);
    expect(candidate.bytes,greaterThan(0));
    expect(candidate.revisions,2);
    expect(candidate.operations,2);
    expect(candidate.mediaFiles,3);
    expect(candidate.eligibleForAutomaticApply,false);
    await ModMonthFullBackupArchiveV1.verifyCloudMedia(
      zipPath:candidate.file.path,
      transport:const CloudTestZipTransport());
    final restored=Directory(temp.path+'/candidate-expanded');
    await restored.create();
    await const CloudTestZipTransport().extract(
      archivePath:candidate.file.path,
      destinationDirectory:restored.path);
    for(final (path,bytes) in [
      (CloudFullZipFixture.currentMedia,CloudFullZipFixture.currentBytes),
      (CloudFullZipFixture.historicalMedia,CloudFullZipFixture.historicalBytes),
      ('media/image/new-photo.png',const [33,44,55,66]),
    ]) {
      expect(await File(restored.path+'/'+path).readAsBytes(),
        orderedEquals(bytes),reason:path);
    }
    final graph=jsonDecode(await File(restored.path+'/'+
      ModMonthVerifiedManifestV2.graphPath).readAsString()) as Map;
    expect((graph['dayPages'] as List).length,1);
    final table=(graph['monthGraph'] as Map)['tables'] as Map;
    expect((table['mod_month_revisions'] as List).length,2);
    expect((table['mod_month_ops'] as List).length,2);
    expect(cloud.ops.where((op)=>op.startsWith('write ') ||
      op.startsWith('create ') || op.startsWith('delete ')).length,writes);
    expect(cloud.objects.containsKey('manifest.json'),false);
  });

  test('identical snapshots can be copied without modifying their versions',
      () async {
    final cloud=FakeRemoteBackend();
    final one=await fixture('only');
    final r=await upload(cloud,one);
    await publish(cloud,r,a);
    await publish(cloud,r,b);
    final result=await build(cloud,'identical.zip');
    expect(result.revisions,2);
    expect(result.operations,2);
    expect(result.mediaFiles,2);
    expect(result.eligibleForAutomaticApply,false);
    await ModMonthFullBackupArchiveV1.verifyCloudMedia(
      zipPath:result.file.path,transport:const CloudTestZipTransport());
  });

  test('edit/delete branch conflict prevents a misleading restorable ZIP',
      () async {
    final cloud=FakeRemoteBackend();
    final edit=await fixture('edit',deleted:false,
      childId:'cloud-history-revision-0003',
      childImageName:'only-edit.png');
    final deleted=await fixture('deleted');
    await publish(cloud,await upload(cloud,edit),a);
    await publish(cloud,await upload(cloud,deleted),b);
    final dst=File(temp.path+'/conflict.zip');
    await expectLater(build(cloud,'conflict.zip'),
      throwsA(isA<ModMonthVersionError>().having(
        (e)=>e.code,'code','revision_conflict_manual_review')));
    expect(await dst.exists(),false);
  });

  test('native diary mismatch rejects candidate even when graph agrees',
      () async {
    final cloud=FakeRemoteBackend();
    final left=await fixture('left');
    final right=await fixture('right',nativeTitle:'changed title');
    await publish(cloud,await upload(cloud,left),a);
    await publish(cloud,await upload(cloud,right),b);
    await expectLater(build(cloud,'native-conflict.zip'),
      throwsA(isA<ModMonthVersionError>().having(
        (e)=>e.code,'code','native_payload_conflict')));
    expect(await File(temp.path+'/native-conflict.zip').exists(),false);
  });

  test('same historical media path with different bytes rejects candidate',
      () async {
    final cloud=FakeRemoteBackend();
    final first=await fixture('first');
    final changed=await fixture('changed',historic:[99,98,97]);
    await publish(cloud,await upload(cloud,first),a);
    await publish(cloud,await upload(cloud,changed),b);
    await expectLater(build(cloud,'media-conflict.zip'),
      throwsA(isA<ModMonthVersionError>().having(
        (e)=>e.code,'code','media_path_conflict')));
    expect(await File(temp.path+'/media-conflict.zip').exists(),false);
  });

  test('damaged remote chunks fail before exposing any candidate',() async {
    final cloud=FakeRemoteBackend();
    final initial=await fixture('initial');
    final newest=await fixture('newest',includeChild:false);
    await publish(cloud,await upload(cloud,initial),a);
    final r=await upload(cloud,newest);
    await publish(cloud,r,b);
    final key=cloud.objects.keys.firstWhere((x)=>x.contains('/chunks/'));
    cloud.objects[key]=Uint8List.fromList([1,2,3]);
    await expectLater(build(cloud,'damaged.zip'),throwsA(anything));
    expect(await File(temp.path+'/damaged.zip').exists(),false);
    expect(cloud.ops.where((op)=>op.startsWith('delete ')),isEmpty);
  });

  test('existing user file is protected BEFORE remote reads',() async {
    final cloud=FakeRemoteBackend();
    final dst=File(temp.path+'/keep.zip');
    await dst.writeAsString('irreplaceable');
    await expectLater(build(cloud,'keep.zip'),
      throwsA(isA<ModMonthVersionError>().having(
        (e)=>e.code,'code','destination_exists')));
    expect(await dst.readAsString(),'irreplaceable');
    expect(cloud.ops,isEmpty);
  });

  test('existing symlink destination is rejected before remote access',
      () async {
    final cloud=FakeRemoteBackend();
    final protected=File(temp.path+'/protected-original.zip');
    await protected.writeAsString('keep this original');
    final link=Link(temp.path+'/linked-candidate.zip');
    await link.create(protected.path);
    await expectLater(build(cloud,'linked-candidate.zip'),
      throwsA(isA<ModMonthVersionError>().having(
        (e)=>e.code,'code','destination_exists')));
    expect(await protected.readAsString(),'keep this original');
    expect(await link.exists(),true);
    expect(cloud.ops,isEmpty);
  });

  test('existing directory destination is rejected before remote access',
      () async {
    final cloud=FakeRemoteBackend();
    final dir=Directory(temp.path+'/directory-candidate.zip');
    await dir.create();
    await expectLater(build(cloud,'directory-candidate.zip'),
      throwsA(isA<ModMonthVersionError>().having(
        (e)=>e.code,'code','destination_exists')));
    expect(await dir.exists(),true);
    expect(cloud.ops,isEmpty);
  });

  test('interrupted remote read fails closed without candidate or writes',
      () async {
    final cloud=FakeRemoteBackend();
    final one=await fixture('one');
    final r=await upload(cloud,one);
    await publish(cloud,r,a);
    await publish(cloud,r,b);
    final before=cloud.objects.length;
    final secondKey=ModMonthRemoteChunkedVersionStoreV1.keyFor(b,snapshot);
    cloud.beforeOp=(op,key){
      if(op=='read'&&key==secondKey){
        throw const SocketException('network offline');
      }
    };
    await expectLater(build(cloud,'interrupted.zip'),
      throwsA(isA<SocketException>()));
    expect(await File(temp.path+'/interrupted.zip').exists(),false);
    expect(cloud.objects.length,before);
    expect(cloud.ops.where((op)=>op.startsWith('delete ')),isEmpty);
  });

  test('destination created after preflight is never overwritten',() async {
    final cloud=FakeRemoteBackend();
    final one=await fixture('race');
    final receipt=await upload(cloud,one);
    await publish(cloud,receipt,a);
    await publish(cloud,receipt,b);
    final dst=File(temp.path+'/race-candidate.zip');
    var injected=false;
    cloud.beforeOp=(op,key){
      if(op=='read' && !injected){
        injected=true;
        dst.writeAsStringSync('new owner data');
      }
    };
    await expectLater(build(cloud,'race-candidate.zip'),
      throwsA(isA<ModMonthVersionError>().having(
        (e)=>e.code,'code','destination_exists')));
    expect(injected,true);
    expect(await dst.readAsString(),'new owner data');
  });

  // Linux CI exercises the exact no-clobber hard-link primitive used by
  // build(). SIGKILL is sent at the publication boundary, after link(1)
  // returns. This complements, but does not replace, Android device tests.
  test('SIGKILL immediately after hard-link publish leaves a complete ZIP',
      () async {
    if(!Platform.isLinux)return;
    final cloud=FakeRemoteBackend();
    final one=await fixture('kill');
    final receipt=await upload(cloud,one);
    await publish(cloud,receipt,a);
    await publish(cloud,receipt,b);
    final candidate=await build(cloud,'verified-before-kill.zip');
    final published=File(temp.path+'/published-before-kill.zip');
    final child=await Process.start('sh',[
      '-c',r'link "$1" "$2" || exit 31; kill -9 "$$"',
      'sh',candidate.file.absolute.path,published.absolute.path,
    ]);
    expect(await child.exitCode,isNot(0));
    expect(await FileSystemEntity.type(published.path,followLinks:false),
      FileSystemEntityType.file);
    expect(await published.readAsBytes(),
      orderedEquals(await candidate.file.readAsBytes()));
    await ModMonthFullBackupArchiveV1.verifyCloudMedia(
      zipPath:published.path,transport:const CloudTestZipTransport());
    final before=await published.readAsBytes();
    final collision=await Process.run('link',[
      candidate.file.absolute.path,published.absolute.path,
    ]);
    expect(collision.exitCode,isNot(0));
    expect(await published.readAsBytes(),orderedEquals(before));
  });

  test('late symlink collision preserves the linked user file',() async {
    final cloud=FakeRemoteBackend();
    final one=await fixture('late-link');
    final receipt=await upload(cloud,one);
    await publish(cloud,receipt,a);
    await publish(cloud,receipt,b);
    final protected=File(temp.path+'/late-protected.zip');
    await protected.writeAsString('must remain intact');
    final dst=Link(temp.path+'/late-link-candidate.zip');
    var injected=false;
    cloud.beforeOp=(op,key){
      if(op=='read' && !injected){
        injected=true;
        dst.createSync(protected.path);
      }
    };
    await expectLater(build(cloud,'late-link-candidate.zip'),
      throwsA(isA<ModMonthVersionError>().having(
        (e)=>e.code,'code','destination_exists')));
    expect(injected,true);
    expect(await protected.readAsString(),'must remain intact');
    expect(await Link(dst.path).exists(),true);
  });

  test('SIGKILL before hard-link publication exposes no final ZIP',() async {
    if(!Platform.isLinux)return;
    final cloud=FakeRemoteBackend();
    final one=await fixture('kill-before');
    final receipt=await upload(cloud,one);
    await publish(cloud,receipt,a);
    await publish(cloud,receipt,b);
    final candidate=await build(cloud,'verified-before-link.zip');
    final published=File(temp.path+'/never-published.zip');
    final child=await Process.start('sh',[
      '-c',r'kill -9 "$$"; link "$1" "$2"',
      'sh',candidate.file.absolute.path,published.absolute.path,
    ]);
    expect(await child.exitCode,isNot(0));
    expect(await FileSystemEntity.type(published.path,followLinks:false),
      FileSystemEntityType.notFound);
    await ModMonthFullBackupArchiveV1.verifyCloudMedia(
      zipPath:candidate.file.path,transport:const CloudTestZipTransport());
  });
}
