// W9: encrypted immutable version descriptors. Staging API, not production sync.
// The legacy manifest, database, local settings and WebDAV gate stay untouched.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:moodiary_sync/src/data/codec.dart';
import 'package:moodiary_sync/src/data/mod_month_webdav_full_zip_v1.dart';
import 'package:moodiary_sync/src/data/mod_month_zip_bundle_v2.dart';
import 'package:moodiary_sync/src/data/sync.dart';

final class ModMonthVersionError implements Exception {
  const ModMonthVersionError(this.code);
  final String code;
  @override
  String toString() => 'ModMonthVersionError($code)';
}

final class ModMonthRemoteVersionV1 {
  const ModMonthRemoteVersionV1({
    required this.deviceId,
    required this.snapshotId,
    required this.parentSnapshotId,
    required this.archiveSha256,
    required this.archiveBytes,
    required this.createdAtMs,
  });
  final String deviceId;
  final String snapshotId;
  final String? parentSnapshotId;
  final String archiveSha256;
  final int archiveBytes;
  final int createdAtMs;

  static const format = 'moodiary-month-remote-version';
  static const version = 1;
  static bool validId(String s) =>
      RegExp(r'^[A-Za-z0-9_-]{8,120}$').hasMatch(s);
  static bool validSha(String s) => RegExp(r'^[0-9a-f]{64}$').hasMatch(s);
  static String hash(Object value) =>
      sha256.convert(utf8.encode(jsonEncode(value))).toString();

  void validate() {
    if (!validId(deviceId) || !validId(snapshotId) ||
        (parentSnapshotId != null &&
          (!validId(parentSnapshotId!) || parentSnapshotId == snapshotId)) ||
        !validSha(archiveSha256) || archiveBytes < 1 ||
        archiveBytes > ModMonthWebdavFullZipV1.maxArchiveBytes ||
        createdAtMs <= 0) {
      throw const ModMonthVersionError('invalid_fields');
    }
  }

  Map<String, Object?> get body => {
    'format': format, 'version': version, 'deviceId': deviceId,
    'snapshotId': snapshotId, 'parentSnapshotId': parentSnapshotId,
    'archiveSha256': archiveSha256, 'archiveBytes': archiveBytes,
    'createdAtMs': createdAtMs,
  };

  String encode() {
    validate();
    return jsonEncode({...body, 'sha256': hash(body)});
  }

  static ModMonthRemoteVersionV1 decode(String text) {
    if (text.length > 4096) throw const ModMonthVersionError('too_large');
    final Object? raw;
    try { raw = jsonDecode(text); }
    catch (_) { throw const ModMonthVersionError('invalid_json'); }
    if (raw is! Map<String,dynamic> || raw.length != 9 ||
        !raw.keys.toSet().containsAll({
          'format','version','deviceId','snapshotId','parentSnapshotId',
          'archiveSha256','archiveBytes','createdAtMs','sha256',
        }) ||
        raw['format'] != format || raw['version'] != version ||
        raw['deviceId'] is! String || raw['snapshotId'] is! String ||
        (raw['parentSnapshotId'] != null &&
          raw['parentSnapshotId'] is! String) ||
        raw['archiveSha256'] is! String || raw['archiveBytes'] is! int ||
        raw['createdAtMs'] is! int || raw['sha256'] is! String) {
      throw const ModMonthVersionError('invalid_schema');
    }
    final value = ModMonthRemoteVersionV1(
      deviceId:raw['deviceId'] as String,
      snapshotId:raw['snapshotId'] as String,
      parentSnapshotId:raw['parentSnapshotId'] as String?,
      archiveSha256:raw['archiveSha256'] as String,
      archiveBytes:raw['archiveBytes'] as int,
      createdAtMs:raw['createdAtMs'] as int,
    );
    value.validate();
    if (hash(value.body) != raw['sha256']) {
      throw const ModMonthVersionError('checksum_mismatch');
    }
    return value;
  }

  bool sameAs(ModMonthRemoteVersionV1 other) => encode() == other.encode();
}

final class ModMonthRemoteVersionStoreV1 {
  const ModMonthRemoteVersionStoreV1._();
  static const prefix = 'mod-full-history/v1/versions/';
  static const maxEncryptedBytes = 8192;

  static Never _fail(String code) => throw ModMonthVersionError(code);
  static String keyFor(String deviceId,String snapshotId) {
    if (!ModMonthRemoteVersionV1.validId(deviceId) ||
        !ModMonthRemoteVersionV1.validId(snapshotId)) {
      _fail('unsafe_path');
    }
    return prefix + deviceId + '/' + snapshotId + '.json.enc';
  }

  static bool _hasCipherHeader(Uint8List bytes) {
    final magic=utf8.encode(SyncCipher.magic);
    if (bytes.length <= magic.length) return false;
    for (var i=0;i<magic.length;i++) {
      if (bytes[i]!=magic[i]) return false;
    }
    return true;
  }

  static Future<ModMonthRemoteVersionV1?> read({
    required RemoteObjectStore backend, required SyncCipher cipher,
    required String deviceId, required String snapshotId,
  }) async {
    if (!cipher.encrypted) _fail('encryption_required');
    final bytes=await backend.readObject(keyFor(deviceId,snapshotId));
    if (bytes==null) return null;
    if (bytes.length > maxEncryptedBytes || !_hasCipherHeader(bytes)) {
      _fail('invalid_encrypted_version');
    }
    final Uint8List data;
    try { data=await cipher.decryptBytes(bytes); }
    catch (_) { _fail('decryption_failed'); }
    final item=ModMonthRemoteVersionV1.decode(
      utf8.decode(data,allowMalformed:false));
    if (item.deviceId!=deviceId || item.snapshotId!=snapshotId) {
      _fail('version_path_mismatch');
    }
    return item;
  }

  /// Never replace a version or publish a "latest" pointer. The caller
  /// supplies the stable per-installation device ID and a new snapshot ID.
  /// Parent chains allow detection of divergent offline snapshot histories.
  static Future<bool> publish({
    required RemoteObjectStore backend, required SyncCipher cipher,
    required ModMonthRemoteVersionV1 snapshot,
    required ModMonthWebdavZipReceipt receipt,
    ModMonthZipTransportV2 zipTransport=const ModMonthNativeZipTransportV2(),
  }) async {
    if (!cipher.encrypted) _fail('encryption_required');
    snapshot.validate();
    if (receipt.sha256!=snapshot.archiveSha256 ||
        receipt.bytes!=snapshot.archiveBytes ||
        receipt.remoteKey!=ModMonthWebdavFullZipV1.keyFor(
          snapshot.archiveSha256)) {
      _fail('archive_receipt_mismatch');
    }
    if (snapshot.parentSnapshotId!=null &&
        await read(backend:backend,cipher:cipher,
          deviceId:snapshot.deviceId,
          snapshotId:snapshot.parentSnapshotId!)==null) {
      _fail('parent_not_published');
    }

    // A caller can forge a receipt: independently re-read and verify the
    // encrypted archive before publishing any version record.
    final temp=await Directory.systemTemp.createTemp('month-ver-publish-');
    try {
      final check=File(temp.path+'/check.zip');
      await ModMonthWebdavFullZipV1.downloadToNewFile(
        backend:backend,cipher:cipher,
        sha256:snapshot.archiveSha256,destination:check,
        zipTransport:zipTransport);
      if (await check.length()!=snapshot.archiveBytes) {
        _fail('archive_size_mismatch');
      }
    } finally {
      if (await temp.exists()) await temp.delete(recursive:true);
    }

    final key=keyFor(snapshot.deviceId,snapshot.snapshotId);
    final existing=await read(backend:backend,cipher:cipher,
      deviceId:snapshot.deviceId,snapshotId:snapshot.snapshotId);
    if (existing!=null) {
      if (!existing.sameAs(snapshot)) _fail('immutable_version_conflict');
      return true;
    }
    final data=await cipher.encryptBytes(Uint8List.fromList(
      utf8.encode(snapshot.encode())));
    if (data.length>maxEncryptedBytes || !_hasCipherHeader(data)) {
      _fail('invalid_encrypted_payload');
    }
    // Conditional If-None-Match:*. Reject unsupported WebDAV providers.
    final result=await backend.tryCreateExclusive(key,data);
    if (result==ExclusiveCreate.unsupported) {
      _fail('exclusive_creation_unsupported');
    }
    final reread=await read(backend:backend,cipher:cipher,
      deviceId:snapshot.deviceId,snapshotId:snapshot.snapshotId);
    if (reread==null || !reread.sameAs(snapshot)) {
      _fail('version_readback_conflict');
    }
    return result==ExclusiveCreate.exists;
  }
}
