// W9: isolated, encrypted, content-addressed full-history ZIP transport.
// This service never writes the legacy manifest, marks sync complete,
// alters SQLite, deletes remote objects, or lifts the structured-data gate.
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:moodiary_sync/src/data/codec.dart';
import 'package:moodiary_sync/src/data/mod_month_zip_preflight_v2.dart';
import 'package:moodiary_sync/src/data/sync.dart';

final class ModMonthWebdavZipException implements Exception {
  const ModMonthWebdavZipException(this.code);
  final String code;
  @override
  String toString() => 'ModMonthWebdavZipException($code)';
}

final class ModMonthWebdavZipReceipt {
  const ModMonthWebdavZipReceipt({
    required this.remoteKey,
    required this.sha256,
    required this.bytes,
    required this.reused,
  });
  final String remoteKey;
  final String sha256;
  final int bytes;
  final bool reused;
}

final class ModMonthWebdavFullZipV1 {
  const ModMonthWebdavFullZipV1._();

  // Separate from the legacy v3 manifest and its ordinary diary paths.
  static const prefix = 'mod-full-history/v1/';
  // Nutstore defaults to a 500 MB per-file quota. This primitive cannot
  // silently truncate or split oversized archives.
  static const maxArchiveBytes = 450 * 1000 * 1000;
  static const maxCipherBytes = 451 * 1000 * 1000;

  static Never _fail(String code) => throw ModMonthWebdavZipException(code);
  static bool _validDigest(String value) =>
      RegExp(r'^[0-9a-f]{64}$').hasMatch(value);

  static String keyFor(String digest) {
    if (!_validDigest(digest)) _fail('unsafe_content_address');
    return prefix + digest + '.zip.enc';
  }

  static Future<String> _hash(File file) async =>
      (await sha256.bind(file.openRead()).first).toString();

  static Future<void> _validateZip(File file) async {
    if (await FileSystemEntity.type(file.path, followLinks: false) !=
        FileSystemEntityType.file) _fail('zip_missing_or_not_regular');
    if (await file.length() > maxArchiveBytes) _fail('zip_too_large');
    final names = await ModMonthZipPreflightV2.inspect(file.path);
    if (!ModMonthZipPreflightV2.hasCompleteFullHistoryMarkers(names)) {
      _fail('not_full_history_backup');
    }
  }

  static void _requireStreamingEncrypted(
    RemoteObjectStore backend, SyncCipher cipher,
  ) {
    if (!backend.supportsFileObjects) _fail('streaming_backend_required');
    if (!cipher.encrypted) _fail('encryption_required');
  }

  static Future<void> _verifyRemote(
    File encrypted, File decrypted, SyncCipher cipher, String digest,
  ) async {
    if (await FileSystemEntity.type(encrypted.path,followLinks:false) !=
        FileSystemEntityType.file) _fail('remote_object_missing');
    if (await encrypted.length() > maxCipherBytes) _fail('remote_too_large');
    // SyncCipher.decryptFileTo deliberately accepts plaintext for legacy
    // objects. Full-history backups MUST NOT accept that fallback.
    if (!await SyncCipher.isCipherFile(encrypted.path)) {
      _fail('remote_not_encrypted');
    }
    await cipher.decryptFileTo(encrypted.path,decrypted.path);
    if (await _hash(decrypted)!=digest) _fail('remote_archive_hash_mismatch');
    await _validateZip(decrypted);
  }

  /// Only creates a versioned immutable remote object. Never publishes a
  /// current-generation pointer and never touches live user state.
  static Future<ModMonthWebdavZipReceipt> upload({
    required RemoteObjectStore backend,
    required SyncCipher cipher,
    required File fullBackupZip,
  }) async {
    _requireStreamingEncrypted(backend,cipher);
    await _validateZip(fullBackupZip);
    final digest = await _hash(fullBackupZip);
    final key = keyFor(digest);
    final temp = await Directory.systemTemp.createTemp('moodiary-zip-upload-');
    try {
      final downloaded = File(temp.path+'/readback.enc');
      final plain = File(temp.path+'/readback.zip');
      if (await backend.readObjectToFile(key,downloaded.path)) {
        await _verifyRemote(downloaded,plain,cipher,digest);
        return ModMonthWebdavZipReceipt(
          remoteKey:key,sha256:digest,bytes:await fullBackupZip.length(),
          reused:true,
        );
      }

      final encrypted=File(temp.path+'/upload.enc');
      await cipher.encryptFileTo(fullBackupZip.path,encrypted.path);
      if (await encrypted.length() > maxCipherBytes ||
          !await SyncCipher.isCipherFile(encrypted.path)) {
        _fail('encrypted_upload_invalid');
      }
      await backend.writeObjectFile(key,encrypted.path);
      // An HTTP PUT alone is never enough to claim a backup succeeded.
      if (!await backend.readObjectToFile(key,downloaded.path)) {
        _fail('upload_readback_missing');
      }
      await _verifyRemote(downloaded,plain,cipher,digest);
      return ModMonthWebdavZipReceipt(
        remoteKey:key,sha256:digest,bytes:await fullBackupZip.length(),
        reused:false,
      );
    } finally {
      if (await temp.exists()) await temp.delete(recursive:true);
    }
  }

  /// Verified download into a NEW isolated file; never import into SQLite.
  static Future<File> downloadToNewFile({
    required RemoteObjectStore backend,
    required SyncCipher cipher,
    required String sha256,
    required File destination,
  }) async {
    _requireStreamingEncrypted(backend,cipher);
    final key=keyFor(sha256);
    if (await FileSystemEntity.type(destination.path,followLinks:false) !=
        FileSystemEntityType.notFound) _fail('destination_exists');
    if (await FileSystemEntity.type(destination.parent.path,followLinks:false)
        != FileSystemEntityType.directory) _fail('destination_parent_missing');
    final temp=await Directory.systemTemp.createTemp('moodiary-zip-down-');
    try {
      final incoming=File(temp.path+'/incoming.enc');
      final verified=File(temp.path+'/verified.zip');
      if (!await backend.readObjectToFile(key,incoming.path)) {
        _fail('remote_object_missing');
      }
      await _verifyRemote(incoming,verified,cipher,sha256);
      // Exclusive creation ensures no existing backup is overwritten even
      // if another process creates the destination after the initial check.
      RandomAccessFile? output;
      var created=false;
      try {
        output=await destination.open(mode:FileMode.writeOnlyExclusive);
        created=true;
        await for(final part in verified.openRead()) {
          await output.writeFrom(part);
        }
        await output.flush();
        await output.close();
        output=null;
        if(await _hash(destination)!=sha256) {
          _fail('destination_hash_mismatch');
        }
        return destination;
      } catch (_) {
        await output?.close();
        if(created && await destination.exists()) await destination.delete();
        rethrow;
      }
    } finally {
      if (await temp.exists()) await temp.delete(recursive:true);
    }
  }
}
