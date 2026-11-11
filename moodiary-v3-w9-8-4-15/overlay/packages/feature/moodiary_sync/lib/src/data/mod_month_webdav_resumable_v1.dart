// W9.8 stage 4: content-addressed encrypted chunks with fail-closed commit.
// STAGING ONLY: no legacy manifest, SQLite, sync status, or app entry changes.
// After a crash, verified chunks are reused; a complete descriptor is written
// last and only via WebDAV conditional create. No remote object is deleted.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:moodiary_sync/src/data/codec.dart';
import 'package:moodiary_sync/src/data/mod_month_full_backup_archive_v1.dart';
import 'package:moodiary_sync/src/data/mod_month_zip_bundle_v2.dart';
import 'package:moodiary_sync/src/data/sync.dart';

final class ModMonthChunkedError implements Exception {
  const ModMonthChunkedError(this.code);
  final String code;
  @override
  String toString() => 'ModMonthChunkedError($code)';
}

final class ModMonthChunkedReceipt {
  const ModMonthChunkedReceipt({
    required this.archiveSha256,
    required this.archiveBytes,
    required this.chunkCount,
    required this.reusedChunks,
    required this.manifestReused,
  });
  final String archiveSha256;
  final int archiveBytes;
  final int chunkCount;
  final int reusedChunks;
  final bool manifestReused;
}

final class _CloudChunkManifest {
  const _CloudChunkManifest({
    required this.archiveSha256,
    required this.archiveBytes,
    required this.chunkSize,
    required this.chunks,
  });

  final String archiveSha256;
  final int archiveBytes;
  final int chunkSize;
  final List<({String sha256, int size})> chunks;

  Map<String, Object?> get body => {
    'format': 'moodiary-resumable-zip',
    'version': 1,
    'archiveSha256': archiveSha256,
    'archiveBytes': archiveBytes,
    'chunkSize': chunkSize,
    'chunks': [
      for (final part in chunks)
        {'sha256': part.sha256, 'size': part.size},
    ],
  };

  String encode() {
    final data = body;
    return jsonEncode({...data, 'sha256': ModMonthWebdavResumableV1.hashJson(data)});
  }

  static _CloudChunkManifest decode(String content) {
    if (utf8.encode(content).length >
        ModMonthWebdavResumableV1.maxManifestBytes) {
      throw const ModMonthChunkedError('manifest_too_large');
    }
    final Object? raw;
    try { raw=jsonDecode(content); }
    catch (_) { throw const ModMonthChunkedError('manifest_bad_json'); }
    if (raw is! Map<String,dynamic> || raw.length!=7 ||
        raw['format']!='moodiary-resumable-zip' || raw['version']!=1 ||
        raw['archiveSha256'] is! String ||
        raw['archiveBytes'] is! int ||
        raw['chunkSize'] is! int ||
        raw['chunks'] is! List ||
        raw['sha256'] is! String) {
      throw const ModMonthChunkedError('manifest_invalid_schema');
    }
    final sha=raw['archiveSha256'] as String;
    final bytes=raw['archiveBytes'] as int;
    final size=raw['chunkSize'] as int;
    final items=raw['chunks'] as List;
    if (!ModMonthWebdavResumableV1.validHash(sha) ||
        bytes<1 || bytes>ModMonthWebdavResumableV1.maxArchiveBytes ||
        size<ModMonthWebdavResumableV1.minChunkBytes ||
        size>ModMonthWebdavResumableV1.defaultChunkBytes ||
        items.isEmpty ||
        items.length>ModMonthWebdavResumableV1.maxChunks ||
        items.length != (bytes+size-1)~/size) {
      throw const ModMonthChunkedError('manifest_invalid_sizes');
    }
    final chunks=<({String sha256,int size})>[];
    var sum=0;
    for(var i=0;i<items.length;i++){
      final obj=items[i];
      if(obj is! Map<String,dynamic> || obj.length!=2 ||
          obj['sha256'] is! String || obj['size'] is! int ||
          !ModMonthWebdavResumableV1.validHash(obj['sha256'] as String)) {
        throw const ModMonthChunkedError('manifest_invalid_chunk');
      }
      final partSize=obj['size'] as int;
      final expected=i==items.length-1 ? bytes-size*i : size;
      if(partSize!=expected || partSize<1 || partSize>size){
        throw const ModMonthChunkedError('manifest_chunk_size_mismatch');
      }
      sum+=partSize;
      chunks.add((sha256:obj['sha256'] as String,size:partSize));
    }
    if(sum!=bytes)throw const ModMonthChunkedError('manifest_total_mismatch');
    final result=_CloudChunkManifest(
      archiveSha256:sha,archiveBytes:bytes,chunkSize:size,chunks:chunks);
    if(result.encode()!=content) {
      throw const ModMonthChunkedError('manifest_integrity_mismatch');
    }
    return result;
  }
}

final class ModMonthWebdavResumableV1 {
  const ModMonthWebdavResumableV1._();

  static const prefix='mod-full-history/v1/resumable/';
  static const defaultChunkBytes=2*1024*1024;
  static const minChunkBytes=512;
  static const maxChunks=4096;
  static const maxArchiveBytes=8*1024*1024*1024;
  static const maxManifestBytes=1024*1024;

  static Never _fail(String code)=>throw ModMonthChunkedError(code);
  static bool validHash(String value) =>
      RegExp(r'^[a-f0-9]{64}$').hasMatch(value);
  static String hashJson(Object value) =>
      sha256.convert(utf8.encode(jsonEncode(value))).toString();
  static String _hashBytes(List<int> value) =>
      sha256.convert(value).toString();
  static Future<String> _fileHash(File file) async =>
      (await sha256.bind(file.openRead()).first).toString();

  static String chunkKey(String digest){
    if(!validHash(digest)) _fail('unsafe_chunk_key');
    return prefix+'chunks/'+digest+'.enc';
  }
  static String manifestKey(String digest){
    if(!validHash(digest)) _fail('unsafe_manifest_key');
    return prefix+'manifests/'+digest+'.json.enc';
  }
  static void _requireEncryption(SyncCipher cipher){
    if(!cipher.encrypted)_fail('encryption_required');
  }
  static Future<Uint8List> _readExactly(
      RandomAccessFile reader,int length) async {
    final output=BytesBuilder(copy:false);
    var remaining=length;
    while(remaining>0){
      final part=await reader.read(remaining>65536?65536:remaining);
      if(part.isEmpty)_fail('source_short_read');
      output.add(part);
      remaining-=part.length;
    }
    return output.takeBytes();
  }

  static Future<Uint8List?> _readChunk({
    required RemoteObjectStore backend,
    required SyncCipher cipher,
    required String digest,
    required int length,
  }) async {
    final encrypted=await backend.readObject(chunkKey(digest));
    if(encrypted==null)return null;
    if(encrypted.length>defaultChunkBytes+4096 ||
       !SyncCipher.isCipherText(encrypted))_fail('chunk_not_encrypted');
    final plain=await cipher.decryptBytes(encrypted);
    if(plain.length!=length || _hashBytes(plain)!=digest) {
      _fail('chunk_hash_mismatch');
    }
    return plain;
  }

  static Future<_CloudChunkManifest?> _readManifest({
    required RemoteObjectStore backend,
    required SyncCipher cipher,
    required String archiveSha256,
  }) async {
    final encrypted=await backend.readObject(manifestKey(archiveSha256));
    if(encrypted==null)return null;
    if(encrypted.length>maxManifestBytes+4096 ||
       !SyncCipher.isCipherText(encrypted))_fail('manifest_not_encrypted');
    final plain=await cipher.decryptBytes(encrypted);
    final _CloudChunkManifest manifest;
    try {
      manifest=_CloudChunkManifest.decode(
        utf8.decode(plain,allowMalformed:false));
    } on ModMonthChunkedError {
      rethrow;
    } catch (_) {
      _fail('manifest_invalid_utf8');
    }
    if(manifest.archiveSha256!=archiveSha256) {
      _fail('manifest_archive_mismatch');
    }
    return manifest;
  }

  /// Restart-safe: each chunk is independently encrypted, content-addressed
  /// and verified by readback. Manifest is committed only after all pieces
  /// and the original file have passed SHA-256 and V2 historical media closure.
  /// Re-upload after crash reuses existing verified chunks across processes.
  static Future<ModMonthChunkedReceipt> upload({
    required RemoteObjectStore backend,
    required SyncCipher cipher,
    required File fullBackupZip,
    ModMonthZipTransportV2 zipTransport=const ModMonthNativeZipTransportV2(),
    int chunkBytes=defaultChunkBytes,
  }) async {
    _requireEncryption(cipher);
    if(chunkBytes<minChunkBytes || chunkBytes>defaultChunkBytes) {
      _fail('unsupported_chunk_size');
    }
    if(await FileSystemEntity.type(
        fullBackupZip.path,followLinks:false)!=FileSystemEntityType.file) {
      _fail('archive_missing');
    }
    final bytes=await fullBackupZip.length();
    if(bytes<1 || bytes>maxArchiveBytes ||
       (bytes+chunkBytes-1)~/chunkBytes>maxChunks) {
      _fail('archive_size_limit');
    }
    final before=await _fileHash(fullBackupZip);
    await ModMonthFullBackupArchiveV1.verifyCloudMedia(
      zipPath:fullBackupZip.path,transport:zipTransport);
    if(await _fileHash(fullBackupZip)!=before) {
      _fail('source_changed_during_verification');
    }
    final pieces=<({String sha256,int size})>[];
    var reused=0;
    final reader=await fullBackupZip.open();
    try {
      var offset=0;
      while(offset<bytes){
        final n=bytes-offset<chunkBytes?bytes-offset:chunkBytes;
        final part=await _readExactly(reader,n);
        final digest=_hashBytes(part);
        pieces.add((sha256:digest,size:n));
        if(await _readChunk(
          backend:backend,cipher:cipher,digest:digest,length:n)!=null){
          reused++;
        }else{
          final ciphertext=await cipher.encryptBytes(part);
          if(!SyncCipher.isCipherText(ciphertext) ||
             ciphertext.length>defaultChunkBytes+4096) {
            _fail('invalid_chunk_cipher');
          }
          final status=await backend.tryCreateExclusive(
            chunkKey(digest),ciphertext);
          if(status==ExclusiveCreate.unsupported) {
            _fail('conditional_create_unsupported');
          }
          if(await _readChunk(
            backend:backend,cipher:cipher,digest:digest,length:n)==null){
            _fail('chunk_readback_missing');
          }
          if(status==ExclusiveCreate.exists)reused++;
        }
        offset+=n;
      }
    } finally {
      await reader.close();
    }
    if(await _fileHash(fullBackupZip)!=before) {
      _fail('source_changed_during_upload');
    }
    final manifest=_CloudChunkManifest(
      archiveSha256:before,archiveBytes:bytes,
      chunkSize:chunkBytes,chunks:pieces);
    final encoded=manifest.encode();
    if(utf8.encode(encoded).length>maxManifestBytes) {
      _fail('manifest_size_limit');
    }
    final current=await _readManifest(
      backend:backend,cipher:cipher,archiveSha256:before);
    if(current!=null && current.encode()!=encoded) {
      _fail('immutable_manifest_conflict');
    }
    if(current==null){
      final data=await cipher.encryptBytes(
        Uint8List.fromList(utf8.encode(encoded)));
      if(!SyncCipher.isCipherText(data) ||
         data.length>maxManifestBytes+4096) {
        _fail('invalid_manifest_cipher');
      }
      final status=await backend.tryCreateExclusive(
        manifestKey(before),data);
      if(status==ExclusiveCreate.unsupported) {
        _fail('conditional_create_unsupported');
      }
    }
    final verified=await _readManifest(
      backend:backend,cipher:cipher,archiveSha256:before);
    if(verified==null || verified.encode()!=encoded) {
      _fail('manifest_readback_mismatch');
    }
    return ModMonthChunkedReceipt(
      archiveSha256:before,archiveBytes:bytes,
      chunkCount:pieces.length,reusedChunks:reused,
      manifestReused:current!=null);
  }

  /// Never installs, restores or merges anything. Reconstruct the entire
  /// archive in private staging, verify the final SHA + historical media,
  /// then create a fresh destination file exclusively.
  static Future<File> downloadToNewFile({
    required RemoteObjectStore backend,
    required SyncCipher cipher,
    required String archiveSha256,
    required File destination,
    ModMonthZipTransportV2 zipTransport=const ModMonthNativeZipTransportV2(),
  }) async {
    _requireEncryption(cipher);
    if(!validHash(archiveSha256))_fail('unsafe_manifest_key');
    if(await FileSystemEntity.type(
        destination.path,followLinks:false)!=FileSystemEntityType.notFound) {
      _fail('destination_exists');
    }
    if(await FileSystemEntity.type(
        destination.parent.path,followLinks:false)!=FileSystemEntityType.directory) {
      _fail('destination_parent_missing');
    }
    final manifest=await _readManifest(
      backend:backend,cipher:cipher,archiveSha256:archiveSha256);
    if(manifest==null)_fail('manifest_not_published');
    final scratch=await Directory.systemTemp.createTemp('month-chunk-down-');
    try {
      final staged=File(scratch.path+'/assembled.zip');
      final out=await staged.open(mode:FileMode.write);
      try {
        for(final chunk in manifest.chunks){
          final bytes=await _readChunk(
            backend:backend,cipher:cipher,
            digest:chunk.sha256,length:chunk.size);
          if(bytes==null)_fail('chunk_missing');
          await out.writeFrom(bytes);
        }
        await out.flush();
      } finally {
        await out.close();
      }
      if(await staged.length()!=manifest.archiveBytes ||
         await _fileHash(staged)!=archiveSha256) {
        _fail('archive_hash_mismatch');
      }
      await ModMonthFullBackupArchiveV1.verifyCloudMedia(
        zipPath:staged.path,transport:zipTransport);
      RandomAccessFile? target;
      var created=false;
      try {
        await destination.create(exclusive:true);
        created=true;
        target=await destination.open(mode:FileMode.writeOnlyAppend);
        await for(final chunk in staged.openRead()){
          await target.writeFrom(chunk);
        }
        await target.flush();
        await target.close();
        target=null;
        if(await _fileHash(destination)!=archiveSha256){
          _fail('destination_hash_mismatch');
        }
        return destination;
      } catch (_) {
        await target?.close();
        if(created && await destination.exists()){
          await destination.delete();
        }
        rethrow;
      }
    } finally {
      if(await scratch.exists()) await scratch.delete(recursive:true);
    }
  }
}
