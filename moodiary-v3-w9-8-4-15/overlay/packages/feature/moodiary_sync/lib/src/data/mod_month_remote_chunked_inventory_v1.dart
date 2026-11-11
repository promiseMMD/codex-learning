// Staging-only, read-only remote snapshot inventory and verified export.
// No live DB, legacy manifest, or remote object may be modified here.
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:moodiary_sync/src/data/codec.dart';
import 'package:moodiary_sync/src/data/mod_month_remote_chunked_versions_v1.dart';
import 'package:moodiary_sync/src/data/mod_month_remote_versions_v1.dart';
import 'package:moodiary_sync/src/data/mod_month_webdav_resumable_v1.dart';
import 'package:moodiary_sync/src/data/mod_month_zip_bundle_v2.dart';
import 'package:moodiary_sync/src/data/sync.dart';

final class ModMonthChunkedInventoryV1 {
  const ModMonthChunkedInventoryV1({
    required this.versions,required this.headsByDevice,
    required this.missingParents,required this.crossDeviceDivergence,
  });
  // Descriptor scan does NOT establish archive media recoverability.
  final List<ModMonthRemoteVersionV1> versions;
  final Map<String,List<String>> headsByDevice;
  final List<String> missingParents;
  final bool crossDeviceDivergence;
  int get deviceCount=>headsByDevice.length;
  bool get needsManualReview=>missingParents.isNotEmpty ||
      crossDeviceDivergence ||
      headsByDevice.values.any((heads)=>heads.length>1);
}

final class ModMonthRemoteChunkedInventoryStoreV1 {
  const ModMonthRemoteChunkedInventoryStoreV1._();
  static const maxVersionDescriptors=4096;
  static Never _fail(String code)=>throw ModMonthVersionError(code);

  /// Treat a missing or corrupt listed entry as a failed scan, never as a
  /// partial version catalog. Only the isolated chunk-version namespace counts.
  static Future<ModMonthChunkedInventoryV1> scan({
    required IRemoteSyncBackend backend,required SyncCipher cipher,
  }) async {
    if(!cipher.encrypted)_fail('encryption_required');
    final prefix=ModMonthRemoteChunkedVersionStoreV1.prefix;
    final keys=(await backend.listObjects())
        .where((key)=>key.startsWith(prefix)).toList()..sort();
    if(keys.length>maxVersionDescriptors)_fail('too_many_versions');
    final seen=<String>{};
    final entries=<ModMonthRemoteVersionV1>[];
    final byDevice=<String,Map<String,ModMonthRemoteVersionV1>>{};
    for(final key in keys){
      if(!seen.add(key))_fail('duplicate_remote_key');
      final parts=key.substring(prefix.length).split('/');
      if(parts.length!=2||!parts[1].endsWith('.json.enc')){
        _fail('unsafe_listed_version_path');
      }
      final owner=parts[0];
      final snapshot=parts[1].substring(0,parts[1].length-'.json.enc'.length);
      if(ModMonthRemoteChunkedVersionStoreV1.keyFor(owner,snapshot)!=key){
        _fail('noncanonical_version_path');
      }
      final item=await ModMonthRemoteChunkedVersionStoreV1.read(
        backend:backend,cipher:cipher,deviceId:owner,snapshotId:snapshot);
      if(item==null)_fail('listed_version_missing');
      (byDevice.putIfAbsent(owner,()=>{}))[snapshot]=item;
      entries.add(item);
    }
    final heads=<String,List<String>>{};
    final orphans=<String>[];
    final owners=byDevice.keys.toList()..sort();
    for(final device in owners){
      final versions=byDevice[device]!;
      final referenced=<String>{};
      for(final entry in versions.values){
        final parent=entry.parentSnapshotId;
        if(parent==null)continue;
        final predecessor=versions[parent];
        if(predecessor==null){
          orphans.add(device+'/'+entry.snapshotId);
        }else{
          if(predecessor.createdAtMs>entry.createdAtMs){
            _fail('nonmonotonic_version_time');
          }
          referenced.add(parent);
        }
      }
      for(final id in versions.keys){
        final visited=<String>{};
        String? cursor=id;
        while(cursor!=null&&versions.containsKey(cursor)){
          if(!visited.add(cursor))_fail('version_cycle');
          cursor=versions[cursor]!.parentSnapshotId;
        }
      }
      final tips=versions.keys.where((id)=>!referenced.contains(id)).toList()
        ..sort();
      heads[device]=List<String>.unmodifiable(tips);
    }
    orphans.sort();
    final uniqueArchives=<String>{
      for(final item in entries)item.archiveSha256
    };
    return ModMonthChunkedInventoryV1(
      versions:List<ModMonthRemoteVersionV1>.unmodifiable(entries),
      headsByDevice:Map<String,List<String>>.unmodifiable(heads),
      missingParents:List<String>.unmodifiable(orphans),
      crossDeviceDivergence:byDevice.length>1 && uniqueArchives.length>1);
  }

  /// Export only a selected snapshot; independent encrypted ZIP + history
  /// media validation is mandatory. Never overwrite any existing destination.
  static Future<File> exportVerifiedSnapshot({
    required RemoteObjectStore backend,required SyncCipher cipher,
    required String deviceId,required String snapshotId,
    required File destination,
    ModMonthZipTransportV2 zipTransport=const ModMonthNativeZipTransportV2(),
  }) async {
    if(!cipher.encrypted)_fail('encryption_required');
    if(await FileSystemEntity.type(destination.path,followLinks:false)
        !=FileSystemEntityType.notFound)_fail('destination_exists');
    if(await FileSystemEntity.type(destination.parent.path,followLinks:false)
        !=FileSystemEntityType.directory)_fail('destination_parent_missing');
    final descriptor=await ModMonthRemoteChunkedVersionStoreV1.read(
      backend:backend,cipher:cipher,
      deviceId:deviceId,snapshotId:snapshotId);
    if(descriptor==null)_fail('snapshot_not_found');
    final scratch=await Directory.systemTemp.createTemp('month-inventory-');
    try {
      final staged=await ModMonthWebdavResumableV1.downloadToNewFile(
        backend:backend,cipher:cipher,
        archiveSha256:descriptor.archiveSha256,
        destination:File(scratch.path+'/verified.zip'),
        zipTransport:zipTransport);
      if(await staged.length()!=descriptor.archiveBytes){
        _fail('snapshot_archive_size_mismatch');
      }
      RandomAccessFile? out;
      var created=false;
      try {
        await destination.create(exclusive:true);
        created=true;
        out=await destination.open(mode:FileMode.writeOnlyAppend);
        await for(final part in staged.openRead())await out.writeFrom(part);
        await out.flush();
        await out.close();
        out=null;
        if(await destination.length()!=descriptor.archiveBytes ||
          (await sha256.bind(destination.openRead()).first).toString()
            !=descriptor.archiveSha256)_fail('export_hash_mismatch');
        return destination;
      }catch(_){
        await out?.close();
        if(created&&await destination.exists())await destination.delete();
        rethrow;
      }
    }finally{
      if(await scratch.exists())await scratch.delete(recursive:true);
    }
  }
}
