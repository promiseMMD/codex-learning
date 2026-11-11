// W9.8 stage 5 readiness: immutable chunk-backed version ledger.
// Staging only. Does not change the legacy ZIP version ledger, the ordinary
// WebDAV manifest, local database, app entry point, or user data.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:moodiary_sync/src/data/codec.dart';
import 'package:moodiary_sync/src/data/mod_month_remote_versions_v1.dart';
import 'package:moodiary_sync/src/data/mod_month_webdav_resumable_v1.dart';
import 'package:moodiary_sync/src/data/mod_month_zip_bundle_v2.dart';
import 'package:moodiary_sync/src/data/sync.dart';

final class ModMonthRemoteChunkedVersionStoreV1 {
  const ModMonthRemoteChunkedVersionStoreV1._();

  // Separate version storage avoids treating a chunk manifest as a legacy
  // single-ZIP object when both versions have the same archive SHA-256.
  static const prefix=ModMonthWebdavResumableV1.prefix+'versions/';
  static const maxEncryptedBytes=8192;

  static Never _fail(String code)=>throw ModMonthVersionError(code);

  static String keyFor(String deviceId,String snapshotId) {
    if(!ModMonthRemoteVersionV1.validId(deviceId) ||
       !ModMonthRemoteVersionV1.validId(snapshotId)){
      _fail('unsafe_path');
    }
    return prefix+deviceId+'/'+snapshotId+'.json.enc';
  }

  static Future<ModMonthRemoteVersionV1?> read({
    required RemoteObjectStore backend,
    required SyncCipher cipher,
    required String deviceId,
    required String snapshotId,
  }) async {
    if(!cipher.encrypted)_fail('encryption_required');
    final data=await backend.readObject(keyFor(deviceId,snapshotId));
    if(data==null)return null;
    if(data.length>maxEncryptedBytes ||
       !SyncCipher.isCipherText(data)){
      _fail('invalid_encrypted_version');
    }
    final Uint8List plain;
    try {
      plain=await cipher.decryptBytes(data);
    } catch (_) {
      _fail('decryption_failed');
    }
    final String text;
    try {
      text=utf8.decode(plain,allowMalformed:false);
    } catch (_) {
      _fail('invalid_version_utf8');
    }
    final result=ModMonthRemoteVersionV1.decode(text);
    if(result.deviceId!=deviceId || result.snapshotId!=snapshotId){
      _fail('version_path_mismatch');
    }
    return result;
  }

  /// A caller-supplied receipt is not authoritative: recover the remote
  /// archive independently from encrypted chunks and verify its exact bytes,
  /// outer SHA-256 and V2 current/historical media closure. Only then publish
  /// an immutable same-device snapshot record with WebDAV CAS + readback.
  static Future<bool> publish({
    required RemoteObjectStore backend,
    required SyncCipher cipher,
    required ModMonthRemoteVersionV1 snapshot,
    required ModMonthChunkedReceipt receipt,
    ModMonthZipTransportV2 zipTransport=const ModMonthNativeZipTransportV2(),
  }) async {
    if(!cipher.encrypted)_fail('encryption_required');
    snapshot.validate();
    if(snapshot.archiveSha256!=receipt.archiveSha256 ||
       snapshot.archiveBytes!=receipt.archiveBytes ||
       receipt.chunkCount<1){
      _fail('chunked_archive_receipt_mismatch');
    }

    if(snapshot.parentSnapshotId!=null &&
       await read(backend:backend,cipher:cipher,
         deviceId:snapshot.deviceId,
         snapshotId:snapshot.parentSnapshotId!)==null){
      _fail('parent_not_published');
    }

    final temp=await Directory.systemTemp.createTemp('month-chunk-ver-');
    try {
      final recovered=await ModMonthWebdavResumableV1.downloadToNewFile(
        backend:backend,cipher:cipher,
        archiveSha256:snapshot.archiveSha256,
        destination:File(temp.path+'/readback.zip'),
        zipTransport:zipTransport);
      if(await recovered.length()!=snapshot.archiveBytes){
        _fail('archive_size_mismatch');
      }
    } finally {
      if(await temp.exists())await temp.delete(recursive:true);
    }

    final key=keyFor(snapshot.deviceId,snapshot.snapshotId);
    final old=await read(backend:backend,cipher:cipher,
      deviceId:snapshot.deviceId,snapshotId:snapshot.snapshotId);
    if(old!=null){
      if(!old.sameAs(snapshot))_fail('immutable_version_conflict');
      return true;
    }
    final bytes=await cipher.encryptBytes(
      Uint8List.fromList(utf8.encode(snapshot.encode())));
    if(bytes.length>maxEncryptedBytes ||
       !SyncCipher.isCipherText(bytes)){
      _fail('invalid_encrypted_payload');
    }
    final result=await backend.tryCreateExclusive(key,bytes);
    if(result==ExclusiveCreate.unsupported){
      _fail('exclusive_creation_unsupported');
    }
    final reread=await read(backend:backend,cipher:cipher,
      deviceId:snapshot.deviceId,snapshotId:snapshot.snapshotId);
    if(reread==null || !reread.sameAs(snapshot)){
      _fail('version_readback_conflict');
    }
    return result==ExclusiveCreate.exists;
  }
}
