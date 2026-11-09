// W9.8.4.1: verified native + W9 month/day graph + media closure.
// Receipts support multi-gigabyte streamed media, never heap-load media.
// This is an isolated STAGING format, not a live restore or WebDAV change.
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:moodiary_data/moodiary_data.dart';
import 'package:moodiary_models/moodiary_models.dart';

import 'mod_month_verified_manifest_v1.dart';
import 'model/manifest.dart';

final class ModMonthVerifiedManifestV2 {
  const ModMonthVerifiedManifestV2._();

  static const format='moodiary-verified-day-bundle';
  static const version=2;
  static const scope='native-structured-and-media';
  static const graphPath='structured/month-day-graph-v2.json';
  static const maxStagedFiles=ModMonthVerifiedManifestV1.maxStagedFiles;
  static const maxStagedBytes=ModMonthVerifiedManifestV1.maxStagedBytes;
  static const maxMetadataBytes=64*1024*1024;
  static const maxMediaFileBytes=64*1024*1024*1024;
  static const maxTotalBytes=512*1024*1024*1024;

  static Never _fail(String code)=>throw ModBundleInvalid(code);
  static String _hash(List<int> data)=>sha256.convert(data).toString();

  /// No ZIP control file is allowed inside the payload. Legacy V1 structured
  /// file must never stand in for the new V2 envelope.
  static bool allowsEntryPath(String name)=>
      name==graphPath ||
      (name!=ModMonthVerifiedManifestV1.graphPath &&
        ModMonthVerifiedManifestV1.allowsEntryPath(name));

  static Set<String> _boundDayDiaryIds(String graphEncoded) {
    final graph=jsonDecode(graphEncoded) as Map<String,dynamic>;
    final days=graph['dayPages'] as List<dynamic>;
    return {
      for(final day in days)
        if(day is Map && day['diary_id'] is String)
          day['diary_id'] as String,
    };
  }

  /// Byte-backed adapter is only for small test fixtures. Real media use
  /// sealWithReceipts and are fingerprinted with streaming SHA-256.
  static String seal({
    required Map<String,Uint8List> staged,
    required bool Function(Diary) isTopic,
  }) {
    var sum=0;
    for(final content in staged.values) {
      sum+=content.lengthInBytes;
      if(sum>maxStagedBytes)_fail('streaming_archive_required');
    }
    return sealWithReceipts(
      receipts:{
        for(final e in staged.entries)
          e.key:(size:e.value.lengthInBytes,sha256:_hash(e.value)),
      },
      metadata:{
        for(final e in staged.entries)
          if(!e.key.startsWith('media/'))e.key:e.value,
      },
      isTopic:isTopic,
    );
  }

  static String sealWithReceipts({
    required Map<String,({int size,String sha256})> receipts,
    required Map<String,Uint8List> metadata,
    required bool Function(Diary) isTopic,
  }) {
    if(receipts.length<3 || receipts.length>maxStagedFiles ||
       !receipts.containsKey('manifest.json') ||
       !receipts.containsKey(graphPath))_fail('required_v2_objects_missing');

    final paths=receipts.keys.toList()..sort();
    var metadataSum=0;
    var total=0;
    for(final path in paths) {
      if(!allowsEntryPath(path))_fail('unsafe_v2_payload_path');
      final receipt=receipts[path]!;
      if(receipt.size<0 ||
         !RegExp(r'^[a-f0-9]{64}$').hasMatch(receipt.sha256)) {
        _fail('invalid_v2_receipt');
      }
      if(path.startsWith('media/') && receipt.size>maxMediaFileBytes) {
        _fail('media_file_too_large');
      }
      total+=receipt.size;
      if(total>maxTotalBytes)_fail('bundle_too_large');
      if(!path.startsWith('media/')) {
        metadataSum+=receipt.size;
        if(receipt.size>maxMetadataBytes || metadataSum>maxMetadataBytes){
          _fail('metadata_too_large');
        }
        final bytes=metadata[path];
        if(bytes==null || bytes.lengthInBytes!=receipt.size ||
           _hash(bytes)!=receipt.sha256){
          _fail('missing_or_changed_metadata');
        }
      }
    }
    if(metadata.keys.any((name)=>
        name.startsWith('media/') || !receipts.containsKey(name))) {
      _fail('unindexed_or_media_metadata');
    }

    // V2 validates the two layered checksums, mapping identity, calendar
    // dates, tombstones, historical revisions and DAG before sealing.
    final String encoded;
    final Map<String,dynamic> graph;
    try {
      encoded=utf8.decode(metadata[graphPath]!,allowMalformed:false);
      ModMonthGraphArchiveV2.verify(encoded);
      graph=jsonDecode(encoded) as Map<String,dynamic>;
    } on ModBundleInvalid {
      rethrow;
    } catch (_) {
      _fail('invalid_v2_graph');
    }

    // The day projection may bind an ordinary native Diary. Verify that
    // every such ID is present as a live native object in the same manifest;
    // V1 closure separately validates month-page bindings and topic identity.
    late final SyncManifest nativeManifest;
    try {
      final raw=jsonDecode(utf8.decode(metadata['manifest.json']!));
      if(raw is! Map<String,dynamic>)_fail('invalid_native_manifest');
      nativeManifest=SyncManifest.fromJson(raw);
    } catch (_) {
      _fail('invalid_native_manifest');
    }
    final nativeDiaryIds={
      for(final entry in nativeManifest.entries.entries)
        if(entry.key.startsWith(SyncKeys.diaryPrefix) && !entry.value.deleted)
          entry.key.substring(SyncKeys.diaryPrefix.length),
    };
    for(final id in _boundDayDiaryIds(encoded)) {
      if(!nativeDiaryIds.contains(id))_fail('bound_day_diary_not_backed_up');
    }

    // Re-use the audited V1 native/media-closure validator with a synthetic
    // (verified) inner month graph. The V1 graph is NOT an actual bundle entry.
    // This checks all native Diary/media references AND ALL historical W9
    // revision media, including deleted/replaced revisions.
    final innerBytes=Uint8List.fromList(
      utf8.encode(jsonEncode(graph['monthGraph'])));
    final innerPath=ModMonthVerifiedManifestV1.graphPath;
    final legacyReceipts=<String,({int size,String sha256})>{
      for(final e in receipts.entries)
        if(e.key!=graphPath)e.key:e.value,
      innerPath:(size:innerBytes.lengthInBytes,sha256:_hash(innerBytes)),
    };
    final legacyMetadata=<String,Uint8List>{
      for(final e in metadata.entries)
        if(e.key!=graphPath)e.key:e.value,
      innerPath:innerBytes,
    };
    final nativeClosure=ModMonthVerifiedManifestV1.sealWithReceipts(
      receipts:legacyReceipts,metadata:legacyMetadata,isTopic:isTopic);
    final old=jsonDecode(nativeClosure) as Map<String,dynamic>;
    final topics=old['topics'] as List<dynamic>;

    final listings=<Map<String,Object?>>[
      for(final path in paths) {
        'path':path,
        'size':receipts[path]!.size,
        'sha256':receipts[path]!.sha256,
      },
    ];
    final body=<String,Object?>{
      'format':format,
      'version':version,
      'scope':scope,
      'topics':topics,
      'legacyClosureSha256':_hash(utf8.encode(nativeClosure)),
      'files':listings,
    };
    return jsonEncode({...body,'sha256':_hash(utf8.encode(jsonEncode(body)))});
  }

  static void verifyWithReceipts({
    required String manifest,
    required Map<String,({int size,String sha256})> receipts,
    required Map<String,Uint8List> metadata,
    required bool Function(Diary) isTopic,
  }) {
    if(utf8.encode(manifest).length>4*1024*1024) {
      _fail('v2_manifest_too_large');
    }
    final Object? payload;
    try {payload=jsonDecode(manifest);} catch(_) {
      _fail('invalid_v2_manifest');
    }
    if(payload is! Map<String,dynamic> || payload.length!=7 ||
       !payload.keys.toSet().containsAll({
         'format','version','scope','topics','legacyClosureSha256',
         'files','sha256',
       }) || payload['format']!=format || payload['version']!=version ||
       payload['scope']!=scope ||
       payload['topics'] is! List || payload['files'] is! List ||
       payload['sha256'] is! String ||
       payload['legacyClosureSha256'] is! String) {
      _fail('invalid_v2_manifest');
    }
    final rebuilt=sealWithReceipts(
      receipts:receipts,metadata:metadata,isTopic:isTopic);
    if(rebuilt!=manifest)_fail('v2_bundle_integrity_mismatch');
  }

  static void verify({
    required String manifest,
    required Map<String,Uint8List> staged,
    required bool Function(Diary) isTopic,
  }) {
    final receipts=<String,({int size,String sha256})>{
      for(final e in staged.entries)
        e.key:(size:e.value.lengthInBytes,sha256:_hash(e.value)),
    };
    verifyWithReceipts(
      manifest:manifest,receipts:receipts,
      metadata:{
        for(final e in staged.entries)
          if(!e.key.startsWith('media/'))e.key:e.value,
      },
      isTopic:isTopic,
    );
  }
}
