// W9.7.3: streaming quarantine directory, SHA readback and atomic publication.
// This is not a ZIP exporter, production restore, or WebDAV transport.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:moodiary_models/moodiary_models.dart';
import 'package:path/path.dart' as p;

import 'impl/local_archive.dart' show ArchiveSink;
import 'mod_month_verified_manifest_v1.dart';

final class ModMonthStreamStageV1 implements ArchiveSink {
  ModMonthStreamStageV1._(this._staging,this.destinationPath);

  static const manifestPath='verified-bundle.json';
  static const maxMetadataBytes=64*1024*1024;
  static const maxFiles=ModMonthVerifiedManifestV1.maxStagedFiles;

  final Directory _staging;
  final String destinationPath;
  final _recorded=<String,({int size,String sha256})>{};
  bool _closed=false;
  bool _published=false;
  int _metadataSize=0;

  String get stagingPath => _staging.path;
  int get stagedCount => _recorded.length;

  static Never _fail(String code) => throw ModBundleInvalid(code);

  static Future<ModMonthStreamStageV1> create(String destination) async {
    final dest=p.normalize(p.absolute(destination));
    final parent=Directory(p.dirname(dest));
    if (await FileSystemEntity.type(parent.path,followLinks:false)!=
        FileSystemEntityType.directory) _fail('output_parent_missing');
    if (await FileSystemEntity.type(dest,followLinks:false)!=
        FileSystemEntityType.notFound) _fail('target_already_exists');
    final temp=await parent.createTemp('.moodiary-w973-');
    return ModMonthStreamStageV1._(temp,dest);
  }

  void _canWrite(String path) {
    if (_closed || _published) _fail('staging_closed');
    if (!ModMonthVerifiedManifestV1.allowsEntryPath(path)) {
      _fail('unsafe_archive_path');
    }
    if (_recorded.containsKey(path)) _fail('duplicate_file_path');
    if (_recorded.length>=maxFiles) _fail('too_many_files');
  }

  File _target(String name) => File(p.joinAll([_staging.path,...name.split('/')]));

  static bool _sameFile(FileStat a,FileStat b) =>
      a.type==FileSystemEntityType.file &&
      b.type==FileSystemEntityType.file &&
      a.size==b.size && a.modified==b.modified && a.changed==b.changed;

  static Future<({int size,String sha256})> _fingerprint(File file) async {
    if (await FileSystemEntity.type(file.path,followLinks:false)!=
        FileSystemEntityType.file) _fail('not_regular_file');
    final before=await file.stat();
    final hash=await sha256.bind(file.openRead()).first;
    final after=await file.stat();
    if (!_sameFile(before,after)) _fail('file_changed_while_hashing');
    return (size:after.size,sha256:hash.toString());
  }

  Future<void> _writeStream(String name,Stream<List<int>> input,
      {String? source,FileStat? sourceStat}) async {
    _canWrite(name);
    final finalFile=_target(name);
    await finalFile.parent.create(recursive:true);
    final partial=File(finalFile.path+'.partial');
    RandomAccessFile? out;
    var size=0;
    try {
      if (await FileSystemEntity.type(partial.path,followLinks:false)!=
          FileSystemEntityType.notFound) _fail('partial_file_collision');
      out=await partial.open(mode:FileMode.write);
      await for (final chunk in input) {
        size+=chunk.length;
        if (size<0) _fail('stream_length_overflow');
        if (!name.startsWith('media/') &&
            size+_metadataSize>maxMetadataBytes) {
          _fail('metadata_stream_limit');
        }
        await out.writeFrom(chunk);
      }
      await out.flush();
      await out.close();
      out=null;
      if (source!=null &&
          !_sameFile(sourceStat!,await File(source).stat())) {
        _fail('source_changed_during_copy');
      }
      await partial.rename(finalFile.path);
      final receipt=await _fingerprint(finalFile);
      if (receipt.size!=size) _fail('stream_readback_size_mismatch');
      _recorded[name]=receipt;
      if (!name.startsWith('media/')) _metadataSize+=size;
    } catch (_) {
      try { await out?.close(); } catch (_) {}
      try { if (await partial.exists()) await partial.delete(); } catch (_) {}
      try { if (await finalFile.exists()) await finalFile.delete(); } catch (_) {}
      rethrow;
    }
  }

  Future<void> _guard(Future<void> Function() operation) async {
    try {
      await operation();
    } catch (_) {
      await abort();
      rethrow;
    }
  }

  @override
  Future<void> addBytes(String path,Uint8List bytes) => _guard(
    () => _writeStream(path,Stream<List<int>>.value(bytes)));

  @override
  Future<void> addLocalFile(String path,String source) => _guard(() async {
    if (await FileSystemEntity.type(source,followLinks:false)!=
        FileSystemEntityType.file) _fail('unsafe_source_file');
    final before=await File(source).stat();
    await _writeStream(path,File(source).openRead(),source:source,
      sourceStat:before);
  });

  /// The native LocalArchive writer calls finish before the W9 graph exists.
  /// It is therefore a no-op; publish is the only finalization boundary.
  @override
  Future<void> finish() async {
    if (_closed || _published) _fail('staging_closed');
  }

  Future<void> abort() async {
    if (_published) return;
    _closed=true;
    if (await _staging.exists()) await _staging.delete(recursive:true);
  }

  static Future<Map<String,({int size,String sha256})>> _scan(
    Directory dir,
  ) async {
    if (await FileSystemEntity.type(dir.path,followLinks:false)!=
        FileSystemEntityType.directory) _fail('archive_not_directory');
    final files=<String,({int size,String sha256})>{};
    await for (final item in dir.list(recursive:true,followLinks:false)) {
      final type=await FileSystemEntity.type(item.path,followLinks:false);
      if (type==FileSystemEntityType.directory) continue;
      if (type!=FileSystemEntityType.file) _fail('unsafe_archive_symlink');
      final relative=p.relative(item.path,from:dir.path).replaceAll(
        p.separator,'/');
      if (relative==manifestPath) continue;
      if (!ModMonthVerifiedManifestV1.allowsEntryPath(relative)) {
        _fail('unexpected_archive_payload');
      }
      if (files.containsKey(relative)) _fail('duplicate_archive_payload');
      if (files.length>=maxFiles) _fail('too_many_files');
      files[relative]=await _fingerprint(File(item.path));
    }
    return files;
  }

  static Future<Map<String,Uint8List>> _readMetadata(
      Directory dir,Iterable<String> paths) async {
    final result=<String,Uint8List>{};
    var total=0;
    for (final path in paths) {
      if (path.startsWith('media/')) continue;
      final file=File(p.joinAll([dir.path,...path.split('/')]));
      final size=(await file.stat()).size;
      total+=size;
      if (size<0 || total>maxMetadataBytes) _fail('metadata_stream_limit');
      result[path]=await file.readAsBytes();
    }
    return result;
  }

  /// Publish a completely sealed local staging DIRECTORY via same-parent
  /// rename. No user records or cloud state are modified by this method.
  Future<String> publish({required bool Function(Diary) isTopic}) async {
    if (_closed || _published) _fail('staging_closed');
    try {
      final current=await _scan(_staging);
      if (current.length!=_recorded.length ||
          current.keys.toSet().difference(_recorded.keys.toSet()).isNotEmpty) {
        _fail('staged_file_set_changed');
      }
      for (final file in _recorded.entries) {
        if (current[file.key]!=file.value) _fail('staged_file_changed');
      }
      final metadata=await _readMetadata(_staging,current.keys);
      final manifest=ModMonthVerifiedManifestV1.sealWithReceipts(
        receipts:current,metadata:metadata,isTopic:isTopic);
      final check=File(p.join(_staging.path,manifestPath));
      final writer=await check.open(mode:FileMode.write);
      try {
        await writer.writeFrom(utf8.encode(manifest));
        await writer.flush();
      } finally {
        await writer.close();
      }
      await verifyPublished(_staging.path,isTopic:isTopic);
      if (await FileSystemEntity.type(destinationPath,followLinks:false)!=
          FileSystemEntityType.notFound) _fail('target_already_exists');
      await _staging.rename(destinationPath);
      _published=true;
      return destinationPath;
    } catch (_) {
      await abort();
      rethrow;
    }
  }

  /// Read-only directory verifier. It also rejects links and extra files.
  static Future<void> verifyPublished(String path,{
    required bool Function(Diary) isTopic,
  }) async {
    final dir=Directory(path);
    final manifest=File(p.join(dir.path,manifestPath));
    if (await FileSystemEntity.type(manifest.path,followLinks:false)!=
        FileSystemEntityType.file) _fail('verified_manifest_missing');
    if ((await manifest.stat()).size>4*1024*1024) {
      _fail('verified_manifest_too_large');
    }
    final value=await manifest.readAsString();
    final scanned=await _scan(dir);
    final metadata=await _readMetadata(dir,scanned.keys);
    ModMonthVerifiedManifestV1.verifyWithReceipts(
      manifest:value,receipts:scanned,metadata:metadata,isTopic:isTopic);
  }
}
