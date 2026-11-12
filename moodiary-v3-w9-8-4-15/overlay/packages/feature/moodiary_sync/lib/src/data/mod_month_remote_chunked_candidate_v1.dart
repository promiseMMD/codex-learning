// W9 stage-5: isolated full-history candidate assembly from two independently
// verified, immutable remote snapshots. No live DB, WebDAV write, backup UI,
// legacy manifest, or production sync entry is touched here.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:moodiary_data/src/mod_month_graph_merge_v2.dart';
import 'package:moodiary_sync/src/data/codec.dart';
import 'package:moodiary_sync/src/data/mod_month_full_backup_archive_v1.dart';
import 'package:moodiary_sync/src/data/model/manifest.dart';
import 'package:moodiary_sync/src/data/mod_month_remote_chunked_inventory_v1.dart';
import 'package:moodiary_sync/src/data/mod_month_remote_chunked_versions_v1.dart';
import 'package:moodiary_sync/src/data/mod_month_remote_versions_v1.dart';
import 'package:moodiary_sync/src/data/mod_month_stream_stage_v2.dart';
import 'package:moodiary_sync/src/data/mod_month_verified_manifest_v2.dart';
import 'package:moodiary_sync/src/data/mod_month_zip_bundle_v2.dart';
import 'package:moodiary_sync/src/data/sync.dart';
import 'package:path/path.dart' as p;

final class ModMonthCandidateReceiptV1 {
  const ModMonthCandidateReceiptV1({
    required this.file,required this.sha256,required this.bytes,
    required this.revisions,required this.operations,
    required this.mediaFiles,required this.leftSha256,
    required this.rightSha256,
  });

  /// Offline verified archive only; never an authorization to apply to SQLite.
  final File file;
  final String sha256;
  final int bytes;
  final int revisions;
  final int operations;
  final int mediaFiles;
  final String leftSha256;
  final String rightSha256;
  bool get eligibleForAutomaticApply=>false;
}

final class ModMonthRemoteChunkedCandidateV1 {
  const ModMonthRemoteChunkedCandidateV1._();
  static const _topicTag='__moodiary_mod_topic_v1';
  static Never _fail(String code)=>throw ModMonthVersionError(code);

  static Future<String> _read(String root,String path) =>
      File(p.joinAll([root,...path.split('/')])).readAsString();

  static File _file(String root,String path) =>
      File(p.joinAll([root,...path.split('/')]));

  // Both V2 manifests have already been checked against every byte by the
  // isolated full-history ZIP verifier. Compare ALL native metadata receipts,
  // not just manifest.json, before taking a copy from either side.
  static Future<Map<String,({int size,String hash})>> _receipts(
    String root,
  ) async {
    final data=jsonDecode(await _read(root,ModMonthStreamStageV2.manifestPath));
    if(data is! Map<String,dynamic> || data['files'] is! List) {
      _fail('candidate_verified_receipts_missing');
    }
    final output=<String,({int size,String hash})>{};
    for(final raw in data['files'] as List){
      if(raw is! Map<String,dynamic> ||
         raw['path'] is! String || raw['size'] is! int ||
         raw['sha256'] is! String) {
        _fail('candidate_receipt_invalid');
      }
      final path=raw['path'] as String;
      final value=(size:raw['size'] as int,hash:raw['sha256'] as String);
      if(!ModMonthVerifiedManifestV2.allowsEntryPath(path) ||
         output.containsKey(path) || value.size<0 ||
         !ModMonthRemoteVersionV1.validSha(value.hash)) {
        _fail('candidate_receipt_invalid');
      }
      output[path]=value;
    }
    if(!output.containsKey('manifest.json') ||
       !output.containsKey(ModMonthVerifiedManifestV2.graphPath)){
      _fail('candidate_receipt_required_missing');
    }
    return output;
  }

  // Native updatedAt is a backup-generation timestamp, not a content
  // revision. Ignore ONLY that field; verify every real entry, deletion,
  // media reference, write token and native metadata file strictly.
  static Future<bool> _sameNativeManifest(String aRoot,String bRoot) async {
    final aRaw=jsonDecode(await _read(aRoot,'manifest.json'));
    final bRaw=jsonDecode(await _read(bRoot,'manifest.json'));
    if(aRaw is! Map<String,dynamic> || bRaw is! Map<String,dynamic>){
      _fail('candidate_native_manifest_invalid');
    }
    final a=SyncManifest.fromJson(aRaw);
    final b=SyncManifest.fromJson(bRaw);
    if(a.version!=b.version || a.writeToken!=b.writeToken ||
       a.entries.length!=b.entries.length)return false;
    for(final item in a.entries.entries){
      final other=b.entries[item.key];
      if(other==null ||
         other.timeMs!=item.value.timeMs ||
         other.deleted!=item.value.deleted ||
         jsonEncode(other.media)!=jsonEncode(item.value.media)){
        return false;
      }
    }
    return true;
  }

  /// Build a new, fully verified ZIP into an absent caller-supplied path.
  /// Only a conflict-free graph plus byte-identical native records and
  /// non-colliding, SHA-bound historical media may be assembled. The inputs
  /// remain untouched even if this function throws or the network drops.
  static Future<ModMonthCandidateReceiptV1> build({
    required RemoteObjectStore backend,
    required SyncCipher cipher,
    required String leftDeviceId,
    required String leftSnapshotId,
    required String rightDeviceId,
    required String rightSnapshotId,
    required File destination,
    ModMonthZipTransportV2 zipTransport=const ModMonthNativeZipTransportV2(),
  }) async {
    if(!cipher.encrypted)_fail('encryption_required');
    if(leftDeviceId==rightDeviceId && leftSnapshotId==rightSnapshotId){
      _fail('same_snapshot_selected');
    }
    if(await FileSystemEntity.type(destination.path,followLinks:false) !=
       FileSystemEntityType.notFound)_fail('destination_exists');
    if(await FileSystemEntity.type(destination.parent.path,followLinks:false) !=
       FileSystemEntityType.directory)_fail('destination_parent_missing');

    // Use a same-filesystem private quarantine. Nothing is exposed to the
    // caller until source downloads, native/media union and ZIP readback pass.
    final tmp=await destination.parent.createTemp('.moodiary-candidate-');
    try {
      Future<ModMonthRemoteVersionV1> verifiedDescriptor(
          String device,String snapshot) async {
        final found=await ModMonthRemoteChunkedVersionStoreV1.read(
          backend:backend,cipher:cipher,
          deviceId:device,snapshotId:snapshot);
        if(found==null)_fail('selected_snapshot_missing');
        return found;
      }
      final left=await verifiedDescriptor(leftDeviceId,leftSnapshotId);
      final right=await verifiedDescriptor(rightDeviceId,rightSnapshotId);

      Future<String> extract(ModMonthRemoteVersionV1 item,String label) async {
        final archived=await ModMonthRemoteChunkedInventoryStoreV1
            .exportVerifiedSnapshot(
          backend:backend,cipher:cipher,
          deviceId:item.deviceId,snapshotId:item.snapshotId,
          destination:File(p.join(tmp.path,label+'.zip')),
          zipTransport:zipTransport);
        return ModMonthZipBundleV2.extractVerifiedIntoIsolatedDirectory(
          zipPath:archived.path,
          outputDirectory:p.join(tmp.path,label),
          isTopic:(diary)=>diary.tags.contains(_topicTag),
          transport:zipTransport);
      }
      final leftDir=await extract(left,'left');
      final rightDir=await extract(right,'right');
      final graph=ModMonthGraphMergeV2.review(
        local:await _read(leftDir,ModMonthVerifiedManifestV2.graphPath),
        remote:await _read(rightDir,ModMonthVerifiedManifestV2.graphPath));
      if(graph.needsManualResolution)_fail('revision_conflict_manual_review');

      final l=await _receipts(leftDir);
      final r=await _receipts(rightDir);
      final graphPath=ModMonthVerifiedManifestV2.graphPath;
      // Metadata may only vary in the W9 graph, never in original
      // diaries/categories/tombstones or their native manifest.
      final allPaths={...l.keys,...r.keys};
      final meta=allPaths.where((path)=>
          path!=graphPath && !path.startsWith('media/')).toList()..sort();
      for(final name in meta){
        if(l[name]==null || r[name]==null){
          _fail('native_payload_conflict');
        }
        if(name=='manifest.json'){
          if(!await _sameNativeManifest(leftDir,rightDir)){
            _fail('native_payload_conflict');
          }
        }else if(l[name]!=r[name]){
          _fail('native_payload_conflict');
        }
      }
      final media=allPaths.where((path)=>path.startsWith('media/')).toList()
        ..sort();
      for(final name in media){
        if(l[name]!=null && r[name]!=null && l[name]!=r[name]){
          _fail('media_path_conflict');
        }
      }

      final stage=await ModMonthStreamStageV2.create(
          p.join(tmp.path,'combined'));
      try {
        for(final name in meta) {
          await stage.addLocalFile(name,_file(leftDir,name).path);
        }
        for(final name in media) {
          final from=l.containsKey(name)?leftDir:rightDir;
          await stage.addLocalFile(name,_file(from,name).path);
        }
        await stage.addBytes(graphPath,
          Uint8List.fromList(utf8.encode(graph.candidateGraph)));
        final sealed=await stage.publish(
          isTopic:(diary)=>diary.tags.contains(_topicTag));
        final zip=await ModMonthZipBundleV2.createVerified(
          sourceDirectory:sealed,
          outputZip:p.join(tmp.path,'verified-candidate.zip'),
          isTopic:(diary)=>diary.tags.contains(_topicTag),
          transport:zipTransport);
        await ModMonthFullBackupArchiveV1.verifyCloudMedia(
          zipPath:zip,transport:zipTransport);
        final verifiedZip=File(zip);
        final sha=(await sha256.bind(verifiedZip.openRead()).first).toString();
        final size=await verifiedZip.length();
        if(size<1)_fail('candidate_zip_empty');

        // Expose the complete candidate in one no-clobber filesystem step.
        // A final-path stream/copy or Dart File.rename() is unsafe: SIGKILL
        // can leave a partial ZIP, and rename can replace existing files.
        if(!Platform.isLinux && !Platform.isAndroid && !Platform.isMacOS){
          _fail('candidate_atomic_publish_unavailable');
        }
        if(await FileSystemEntity.type(destination.path,followLinks:false)!=
           FileSystemEntityType.notFound)_fail('destination_exists');
        final handle=await verifiedZip.open(mode:FileMode.append);
        try{
          await handle.flush();
        }finally{
          await handle.close();
        }
        // POSIX link(1) creates an atomic, non-replacing hard link. Both
        // paths reside under destination.parent (same filesystem). No shell
        // is used. If the platform or storage cannot do this, fail closed.
        final source=verifiedZip.absolute.path;
        final target=destination.absolute.path;
        ProcessResult result;
        try{
          result=await Process.run('link',[source,target]);
        }on ProcessException{
          _fail('candidate_atomic_publish_unavailable');
        }
        if(result.exitCode!=0){
          if(await FileSystemEntity.type(destination.path,followLinks:false)!=
             FileSystemEntityType.notFound)_fail('destination_exists');
          _fail('candidate_atomic_publish_unavailable');
        }
        if(!await FileSystemEntity.identical(source,target) ||
           await destination.length()!=size ||
           (await sha256.bind(destination.openRead()).first).toString()!=sha){
          _fail('candidate_export_hash_mismatch');
        }
        return ModMonthCandidateReceiptV1(
          file:destination,sha256:sha,bytes:size,
          revisions:graph.revisionCount,operations:graph.operationCount,
          mediaFiles:media.length,leftSha256:left.archiveSha256,
          rightSha256:right.archiveSha256);
      }catch(_){
        await stage.abort();
        rethrow;
      }
    }finally{
      if(await tmp.exists())await tmp.delete(recursive:true);
    }
  }
}
