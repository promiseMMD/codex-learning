import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:moodiary_data/src/mod_month_graph_merge_v2.dart';
import 'package:moodiary_sync/src/data/codec.dart';
import 'package:moodiary_sync/src/data/mod_month_remote_chunked_history_audit_v1.dart';
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
  const deviceA='device-0001',deviceB='device-0002';
  const snapshot='snapshot-001';
  late Directory temp;
  setUp(() async {
    temp=await Directory.systemTemp.createTemp('month-2device-review-');
  });
  tearDown(() async {
    if(await temp.exists())await temp.delete(recursive:true);
  });

  Future<CloudFullZipFixture> fixture(String name,{
    String childId='cloud-history-revision-0002',
    bool deleted=true,
    String nativeTitle='cloud backup',
    List<int>? historicalMediaBytes,
  }) async {
    final dir=Directory(temp.path+'/'+name);
    await dir.create();
    return CloudFullZipFixture.create(dir,
      childRevisionId:childId,
      childDeleted:deleted,
      nativeTitle:nativeTitle,
      historicalMediaBytes:historicalMediaBytes);
  }

  Future<ModMonthChunkedReceipt> upload(
    FakeRemoteBackend backend,CloudFullZipFixture fixture) =>
      ModMonthWebdavResumableV1.upload(
        backend:backend,cipher:cipher,fullBackupZip:fixture.zip,
        chunkBytes:512,zipTransport:const CloudTestZipTransport());

  Future<void> publish(FakeRemoteBackend backend,
    ModMonthChunkedReceipt receipt,String owner) async {
    await ModMonthRemoteChunkedVersionStoreV1.publish(
      backend:backend,cipher:cipher,
      snapshot:ModMonthRemoteVersionV1(
        deviceId:owner,snapshotId:snapshot,parentSnapshotId:null,
        archiveSha256:receipt.archiveSha256,
        archiveBytes:receipt.archiveBytes,createdAtMs:1000),
      receipt:receipt,zipTransport:const CloudTestZipTransport());
  }

  Future<ModMonthChunkedHistoryAuditV1> review(FakeRemoteBackend cloud) =>
    ModMonthRemoteChunkedHistoryAuditStoreV1.review(
      backend:cloud,cipher:cipher,
      leftDeviceId:deviceA,leftSnapshotId:snapshot,
      rightDeviceId:deviceB,rightSnapshotId:snapshot,
      zipTransport:const CloudTestZipTransport());

  test('identical verified archives preserve all history with no writes',() async {
    final cloud=FakeRemoteBackend();
    final backup=await fixture('same');
    final receipt=await upload(cloud,backup);
    await publish(cloud,receipt,deviceA);
    await publish(cloud,receipt,deviceB);
    final writesBefore=cloud.ops.where((x)=>x.startsWith('create ') ||
      x.startsWith('write ') || x.startsWith('delete ')).length;
    final result=await review(cloud);
    expect(result.archivesDiffer,false);
    expect(result.nativeArchiveDiffers,false);
    expect(result.mediaPathConflicts,isEmpty);
    expect(result.mediaPathCount,2);
    expect(result.graph.revisionCount,2);
    expect(result.graph.operationCount,2);
    expect(result.graph.conflictHeads,isEmpty);
    expect(result.needsManualReview,false);
    expect(result.eligibleForAutomaticApply,false,
      reason:'verified graph is NOT a merged native/media archive');
    expect(cloud.ops.where((x)=>x.startsWith('create ') ||
      x.startsWith('write ') || x.startsWith('delete ')).length,writesBefore);
  });

  test('offline edit vs deletion retains both heads and all operations',() async {
    final cloud=FakeRemoteBackend();
    final edit=await fixture('edit',
      childId:'cloud-history-revision-0003',deleted:false);
    final deletion=await fixture('delete');
    await publish(cloud,await upload(cloud,edit),deviceA);
    await publish(cloud,await upload(cloud,deletion),deviceB);
    final result=await review(cloud);
    expect(result.graph.revisionCount,3);
    expect(result.graph.operationCount,3);
    expect(result.graph.conflictHeads['cloud-history-block-0001'],
      ['cloud-history-revision-0002','cloud-history-revision-0003']);
    expect(result.graph.deletionConflictHeads['cloud-history-block-0001'],
      ['cloud-history-revision-0002']);
    expect(result.mediaPathConflicts,isEmpty);
    expect(result.needsManualReview,true);
    expect(result.eligibleForAutomaticApply,false);
    expect(cloud.objects.containsKey('manifest.json'),false);
    expect(cloud.ops.where((op)=>op.startsWith('delete ')),isEmpty);
  });

  test('same media pathname with different verified bytes is a conflict',() async {
    final cloud=FakeRemoteBackend();
    final normal=await fixture('normal');
    final changed=await fixture('altered',
      historicalMediaBytes:[5,6,7,8,9,10]);
    await publish(cloud,await upload(cloud,normal),deviceA);
    await publish(cloud,await upload(cloud,changed),deviceB);
    final result=await review(cloud);
    expect(result.graph.conflictHeads,isEmpty);
    expect(result.mediaPathCount,2);
    expect(result.mediaPathConflicts,['media/image/history.png']);
    expect(result.needsManualReview,true);
    expect(result.eligibleForAutomaticApply,false);
  });

  test('different native diaries are not disguised as a safe graph merge',() async {
    final cloud=FakeRemoteBackend();
    final normal=await fixture('normal');
    final changed=await fixture('native-edit',nativeTitle:'edited title');
    await publish(cloud,await upload(cloud,normal),deviceA);
    await publish(cloud,await upload(cloud,changed),deviceB);
    final result=await review(cloud);
    expect(result.graph.conflictHeads,isEmpty);
    expect(result.nativeArchiveDiffers,true);
    expect(result.needsManualReview,true);
    expect(result.eligibleForAutomaticApply,false);
  });

  test('colliding immutable revision IDs fail closed instead of overwriting',
      () async {
    final cloud=FakeRemoteBackend();
    final left=await fixture('left');
    final right=await fixture('right',deleted:false);
    await publish(cloud,await upload(cloud,left),deviceA);
    await publish(cloud,await upload(cloud,right),deviceB);
    await expectLater(review(cloud),
      throwsA(isA<ModMonthGraphMergeException>().having(
        (e)=>e.code,'code','identity_conflict_mod_month_revisions')));
    expect(cloud.ops.where((x)=>x.startsWith('delete ')),isEmpty);
  });

  test('missing remote second archive aborts whole audit without updates',
      () async {
    final cloud=FakeRemoteBackend();
    final first=await fixture('first');
    final second=await fixture('second',
      childId:'cloud-history-revision-0003',deleted:false);
    final a=await upload(cloud,first),b=await upload(cloud,second);
    await publish(cloud,a,deviceA);
    await publish(cloud,b,deviceB);
    cloud.objects.remove(ModMonthWebdavResumableV1.manifestKey(b.archiveSha256));
    final previous=cloud.ops.where((x)=>x.startsWith('write ') ||
      x.startsWith('create ') || x.startsWith('delete ')).length;
    await expectLater(review(cloud),
      throwsA(isA<ModMonthChunkedError>().having(
        (e)=>e.code,'code','manifest_not_published')));
    expect(cloud.ops.where((x)=>x.startsWith('write ') ||
      x.startsWith('create ') || x.startsWith('delete ')).length,previous);
    expect(cloud.objects.containsKey('manifest.json'),false);
  });

  test('interrupted remote read rejects incomplete two-device audit',() async {
    final cloud=FakeRemoteBackend();
    final backup=await fixture('one');
    final receipt=await upload(cloud,backup);
    await publish(cloud,receipt,deviceA);
    await publish(cloud,receipt,deviceB);
    final second=ModMonthRemoteChunkedVersionStoreV1.keyFor(
      deviceB,snapshot);
    cloud.beforeOp=(op,key){
      if(op=='read' && key==second) {
        throw const SocketException('network dropped before remote review');
      }
    };
    await expectLater(review(cloud),throwsA(isA<SocketException>()));
    expect(cloud.ops.where((x)=>x.startsWith('delete ')),isEmpty);
  });
}
