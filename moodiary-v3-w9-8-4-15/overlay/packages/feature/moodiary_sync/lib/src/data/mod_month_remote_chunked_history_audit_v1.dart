// W9 stage-5 audit-only: two selected, independently verified WebDAV
// full-history snapshots -> immutable graph review, media collision audit.
// No live SQLite changes, remote writes, automatic merge, or recovery apply.
import 'dart:convert';
import 'dart:io';

import 'package:moodiary_data/src/mod_month_graph_merge_v2.dart';
import 'package:moodiary_sync/src/data/codec.dart';
import 'package:moodiary_sync/src/data/mod_month_remote_chunked_inventory_v1.dart';
import 'package:moodiary_sync/src/data/mod_month_remote_chunked_versions_v1.dart';
import 'package:moodiary_sync/src/data/mod_month_remote_versions_v1.dart';
import 'package:moodiary_sync/src/data/mod_month_verified_manifest_v2.dart';
import 'package:moodiary_sync/src/data/mod_month_zip_bundle_v2.dart';
import 'package:moodiary_sync/src/data/sync.dart';
import 'package:path/path.dart' as p;

final class ModMonthChunkedHistoryAuditV1 {
  const ModMonthChunkedHistoryAuditV1({
    required this.left,
    required this.right,
    required this.graph,
    required this.nativeArchiveDiffers,
    required this.mediaPathConflicts,
    required this.mediaPathCount,
    required this.archivesDiffer,
  });

  final ModMonthRemoteVersionV1 left;
  final ModMonthRemoteVersionV1 right;

  /// Verified, lossless GRAPH candidate only. Not a native/media restore ZIP.
  /// Must never be imported directly into a live database.
  final ModMonthGraphMergeReviewV2 graph;

  /// Different native manifest bytes require manual reconciliation of
  /// ordinary diaries/categories/tombstones, even if the month graph matches.
  final bool nativeArchiveDiffers;

  /// Two independently verified backups reference the same media path with
  /// different SHA-256 values; neither must silently overwrite the other.
  final List<String> mediaPathConflicts;
  final int mediaPathCount;
  final bool archivesDiffer;

  bool get needsManualReview =>
      graph.needsManualResolution ||
      nativeArchiveDiffers ||
      mediaPathConflicts.isNotEmpty ||
      archivesDiffer;

  /// Always false: no merged native/media bundle has been generated, and
  /// a graph-only union is not eligible for restore to any live database.
  bool get eligibleForAutomaticApply => false;
}

final class ModMonthRemoteChunkedHistoryAuditStoreV1 {
  const ModMonthRemoteChunkedHistoryAuditStoreV1._();
  static const _topicTag='__moodiary_mod_topic_v1';

  static Never _fail(String code)=>throw ModMonthVersionError(code);

  static Map<String,String> _verifiedMediaReceipts(String json) {
    final raw=jsonDecode(json);
    if(raw is! Map<String,dynamic> || raw['files'] is! List){
      _fail('verified_bundle_metadata_missing');
    }
    final result=<String,String>{};
    for(final entry in raw['files'] as List){
      if(entry is! Map<String,dynamic> ||
          entry['path'] is! String || entry['sha256'] is! String){
        _fail('verified_bundle_receipt_invalid');
      }
      final name=entry['path'] as String;
      if(name.startsWith('media/')){
        if(result.containsKey(name))_fail('duplicate_media_receipt');
        result[name]=entry['sha256'] as String;
      }
    }
    return result;
  }

  /// Read and validate BOTH remote snapshots. A partial/failed download or
  /// corrupted media aborts the whole review. The temporary directory is
  /// private and removed in every path, including network failures.
  static Future<ModMonthChunkedHistoryAuditV1> review({
    required IRemoteSyncBackend backend,
    required SyncCipher cipher,
    required String leftDeviceId,
    required String leftSnapshotId,
    required String rightDeviceId,
    required String rightSnapshotId,
    ModMonthZipTransportV2 zipTransport=const ModMonthNativeZipTransportV2(),
  }) async {
    if(!cipher.encrypted)_fail('encryption_required');
    if(leftDeviceId==rightDeviceId &&
       leftSnapshotId==rightSnapshotId)_fail('same_snapshot_selected');
    final left=await ModMonthRemoteChunkedVersionStoreV1.read(
      backend:backend,cipher:cipher,
      deviceId:leftDeviceId,snapshotId:leftSnapshotId);
    final right=await ModMonthRemoteChunkedVersionStoreV1.read(
      backend:backend,cipher:cipher,
      deviceId:rightDeviceId,snapshotId:rightSnapshotId);
    if(left==null||right==null)_fail('selected_snapshot_missing');

    final scratch=await Directory.systemTemp.createTemp('month-history-audit-');
    try {
      Future<String> unpack(ModMonthRemoteVersionV1 version,String name) async {
        final file=await ModMonthRemoteChunkedInventoryStoreV1
            .exportVerifiedSnapshot(
          backend:backend,cipher:cipher,
          deviceId:version.deviceId,snapshotId:version.snapshotId,
          destination:File(p.join(scratch.path,name+'.zip')),
          zipTransport:zipTransport);
        return ModMonthZipBundleV2.extractVerifiedIntoIsolatedDirectory(
          zipPath:file.path,
          outputDirectory:p.join(scratch.path,name),
          isTopic:(diary)=>diary.tags.contains(_topicTag),
          transport:zipTransport);
      }
      final leftDir=await unpack(left,'left');
      final rightDir=await unpack(right,'right');

      Future<String> load(String root,String item) async =>
        File(p.joinAll([root,...item.split('/')])).readAsString();

      final leftGraph=await load(leftDir,ModMonthVerifiedManifestV2.graphPath);
      final rightGraph=await load(rightDir,ModMonthVerifiedManifestV2.graphPath);
      final graph=ModMonthGraphMergeV2.review(
        local:leftGraph,remote:rightGraph);

      final leftNative=await load(leftDir,'manifest.json');
      final rightNative=await load(rightDir,'manifest.json');

      final leftFiles=_verifiedMediaReceipts(
        await load(leftDir,'verified-day-bundle-v2.json'));
      final rightFiles=_verifiedMediaReceipts(
        await load(rightDir,'verified-day-bundle-v2.json'));
      final clashes=<String>[
        for(final path in leftFiles.keys)
          if(rightFiles.containsKey(path) &&
             rightFiles[path]!=leftFiles[path])path
      ]..sort();
      return ModMonthChunkedHistoryAuditV1(
        left:left,right:right,
        graph:graph,
        nativeArchiveDiffers:leftNative!=rightNative,
        mediaPathConflicts:List<String>.unmodifiable(clashes),
        mediaPathCount:{...leftFiles.keys,...rightFiles.keys}.length,
        archivesDiffer:left.archiveSha256!=right.archiveSha256,
      );
    }finally{
      if(await scratch.exists())await scratch.delete(recursive:true);
    }
  }
}
