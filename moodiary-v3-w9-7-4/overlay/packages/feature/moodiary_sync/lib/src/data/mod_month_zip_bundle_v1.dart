// W9.7.4: ZIP packaging of a *verified* W9.7.3 staged directory.
// No live database writes, no WebDAV transport and no production backup UI.
import 'dart:io';

import 'package:fast_zip/fast_zip.dart' as native;
import 'package:moodiary_models/moodiary_models.dart';
import 'package:path/path.dart' as p;

import 'mod_month_stream_stage_v1.dart';
import 'mod_month_verified_manifest_v1.dart';
import 'mod_month_zip_preflight_v1.dart';

/// Separate I/O codec allows the same ZIP security and lifecycle tests to
/// exercise a CLI ZIP backend in CI, where Flutter Rust assets are disabled.
abstract interface class ModMonthZipTransportV1 {
  Future<void> create({
    required String archivePath,
    required String sourceDirectory,
    required List<String> entries,
  });
  Future<void> extract({
    required String archivePath,
    required String destinationDirectory,
  });
}

final class ModMonthNativeZipTransportV1 implements ModMonthZipTransportV1 {
  const ModMonthNativeZipTransportV1();

  @override
  Future<void> create({
    required String archivePath,
    required String sourceDirectory,
    required List<String> entries,
  }) async {
    await native.FastZip.ensureInitialized();
    final writer = await native.Zip.newInstance(filePath: archivePath);
    try {
      for (final entry in entries) {
        final local = p.joinAll([sourceDirectory,...entry.split('/')]);
        // Stored files are streamed in Rust, avoiding Dart heap copies and
        // unnecessary recompression of image/video/audio payloads.
        await writer.addFile(
          filePath: local,zipPath:entry,stored:true);
      }
      await writer.finish();
    } finally {
      writer.dispose();
    }
  }

  @override
  Future<void> extract({
    required String archivePath,
    required String destinationDirectory,
  }) async {
    await native.FastZip.ensureInitialized();
    await native.Zip.extract(
      zipPath:archivePath,
      destDir:destinationDirectory,
      cancel:native.CancelToken(),
    );
  }
}

final class ModMonthZipBundleV1 {
  const ModMonthZipBundleV1._();
  static Never _fail(String code) => throw ModBundleInvalid(code);

  static Future<void> _absent(String destination) async {
    if (await FileSystemEntity.type(destination,followLinks:false)!=
        FileSystemEntityType.notFound) {
      _fail('target_already_exists');
    }
  }

  static Future<Directory> _quarantine(String destination) async {
    final parent=Directory(p.dirname(p.normalize(p.absolute(destination))));
    if (await FileSystemEntity.type(parent.path,followLinks:false)!=
        FileSystemEntityType.directory) _fail('output_parent_missing');
    return parent.createTemp('.moodiary-w974-');
  }

  static Future<List<String>> _payloadNames(String dir) async {
    final root=Directory(dir);
    if (await FileSystemEntity.type(root.path,followLinks:false)!=
        FileSystemEntityType.directory) _fail('archive_not_directory');
    final paths=<String>[];
    await for (final item in root.list(recursive:true,followLinks:false)) {
      final type=await FileSystemEntity.type(item.path,followLinks:false);
      if (type==FileSystemEntityType.directory) continue;
      if (type!=FileSystemEntityType.file) _fail('unsafe_source_symlink');
      final path=p.relative(item.path,from:root.path).replaceAll(
        p.separator,'/');
      if (path!='verified-bundle.json' &&
          !ModMonthVerifiedManifestV1.allowsEntryPath(path)) {
        _fail('unexpected_source_entry');
      }
      if (paths.length>=ModMonthZipPreflightV1.maxEntries) {
        _fail('zip_entry_limit');
      }
      paths.add(path);
    }
    paths.sort();
    return paths;
  }

  /// Build a ZIP in a same-parent private quarantine; preflight and extract
  /// the ZIP into a second private directory; validate every extracted byte
  /// against W9.7.3 SHA manifest; only then rename to an absent destination.
  static Future<String> createVerified({
    required String sourceDirectory,
    required String outputZip,
    required bool Function(Diary) isTopic,
    ModMonthZipTransportV1 transport = const ModMonthNativeZipTransportV1(),
  }) async {
    final destination=p.normalize(p.absolute(outputZip));
    await _absent(destination);
    await ModMonthStreamStageV1.verifyPublished(
      sourceDirectory,isTopic:isTopic);
    final sourceManifest=await File(p.join(sourceDirectory,
      ModMonthStreamStageV1.manifestPath)).readAsString();
    final names=await _payloadNames(sourceDirectory);
    final temp=await _quarantine(destination);
    final tempZip=p.join(temp.path,'pending.zip');
    final testExtract=p.join(temp.path,'readback');
    try {
      await transport.create(
        archivePath:tempZip,
        sourceDirectory:sourceDirectory,
        entries:names,
      );
      final listed=await ModMonthZipPreflightV1.inspect(tempZip);
      if (listed.length!=names.length ||
          listed.toSet().difference(names.toSet()).isNotEmpty) {
        _fail('zip_entry_set_differs_from_source');
      }
      await Directory(testExtract).create();
      await transport.extract(archivePath:tempZip,
        destinationDirectory:testExtract);
      await ModMonthStreamStageV1.verifyPublished(
        testExtract,isTopic:isTopic);
      final extractedManifest=await File(p.join(testExtract,
        ModMonthStreamStageV1.manifestPath)).readAsString();
      if (sourceManifest!=extractedManifest) {
        _fail('zip_payload_not_identical');
      }
      // Check the source again, after ZIP build and readback, to catch
      // cooperative concurrent edits before publishing the ZIP file.
      await ModMonthStreamStageV1.verifyPublished(
        sourceDirectory,isTopic:isTopic);
      await _absent(destination);
      await File(tempZip).rename(destination);
      return destination;
    } finally {
      if (await temp.exists()) await temp.delete(recursive:true);
    }
  }

  /// Read an untrusted ZIP only into an explicit, empty isolated directory.
  /// It is NOT a native Diary restore, nor is it wired to the backup UI.
  static Future<String> extractVerifiedIntoIsolatedDirectory({
    required String zipPath,
    required String outputDirectory,
    required bool Function(Diary) isTopic,
    ModMonthZipTransportV1 transport = const ModMonthNativeZipTransportV1(),
  }) async {
    final destination=p.normalize(p.absolute(outputDirectory));
    await _absent(destination);
    await ModMonthZipPreflightV1.inspect(zipPath);
    final quarantine=await _quarantine(destination);
    try {
      await transport.extract(
        archivePath:zipPath,destinationDirectory:quarantine.path);
      await ModMonthStreamStageV1.verifyPublished(
        quarantine.path,isTopic:isTopic);
      await _absent(destination);
      await quarantine.rename(destination);
      return destination;
    } finally {
      if (await quarantine.exists()) {
        await quarantine.delete(recursive:true);
      }
    }
  }
}
