import 'dart:convert';
import 'dart:io';

import 'package:moodiary_models/moodiary_models.dart';
import 'package:path/path.dart' as p;

import 'mod_month_isolated_restore_v2.dart';
import 'mod_month_recovery_slot_v2.dart';
import 'mod_month_verified_manifest_v1.dart' show ModBundleInvalid;
import 'mod_month_verified_manifest_v2.dart';
import 'mod_month_zip_bundle_v2.dart';

/// W9.8.4.6: ZIP cold restore into a private immutable V2 generation.
///
/// A preview is owned by this call only after it is freshly published by the
/// isolated restore. Cleanup refuses to touch a replaced, symlinked, or
/// unexpectedly modified preview. Never point this test-only API at live app
/// storage; it does not activate production restore or WebDAV.
final class ModMonthZipGenerationInstallV2 {
  const ModMonthZipGenerationInstallV2._();

  static Never _unsafe() =>
      throw const ModBundleInvalid('preview_cleanup_unsafe');

  /// The preview must not alias or nest inside the isolated generation slot.
  /// Resolve the existing parent, rather than only comparing lexical paths:
  /// a symlink to the slot root otherwise bypasses a simple prefix check.
  /// This is a preflight fence, not a defense against privileged races.
  static Future<void> _checkPreviewIsolation(
    Directory preview, ModMonthRecoverySlotV2 slot,
  ) async {
    final String parentReal;
    final String slotReal;
    try {
      parentReal=await Directory(p.dirname(preview.path)).resolveSymbolicLinks();
      slotReal=await Directory(slot.root).resolveSymbolicLinks();
    } on FileSystemException {
      throw const ModBundleInvalid('preview_isolation_unverifiable');
    }
    final intended=p.normalize(p.join(parentReal,p.basename(preview.path)));
    final protected=p.normalize(slotReal);
    if (intended==protected || p.isWithin(protected,intended) ||
        p.isWithin(intended,protected)) {
      throw const ModBundleInvalid('preview_slot_path_overlap');
    }
  }

  /// Record only recognized, regular restore payload files. This is a
  /// same-process accidental-overwrite guard, not a security boundary against
  /// a privileged process racing arbitrary filesystem operations.
  static Future<String> _receipt(Directory directory) async {
    if (await FileSystemEntity.type(
          directory.path, followLinks: false) != FileSystemEntityType.directory) {
      _unsafe();
    }

    final state=File(p.join(directory.path,'restore-state.json'));
    if (await FileSystemEntity.type(state.path,followLinks:false)!=
        FileSystemEntityType.file) _unsafe();
    final length=await state.length();
    if (length<2 || length>4096) _unsafe();

    final Object? status;
    try {
      status=jsonDecode(await state.readAsString());
    } catch (_) {
      _unsafe();
    }
    if (status is! Map<String,dynamic> || status.length!=4 ||
        status['format']!='moodiary-v2-isolated-restore' ||
        status['version']!=2 || status['phase']!='ready' ||
        status['liveDataModified']!=false) _unsafe();

    var hasSqlite=false;
    var hasState=false;
    final records=<String>[];
    await for (final entry in directory.list(
        recursive:true,followLinks:false)) {
      final kind=await FileSystemEntity.type(entry.path,followLinks:false);
      final relative=p.relative(entry.path,from:directory.path)
          .replaceAll(p.separator,'/');
      if (kind==FileSystemEntityType.directory) {
        if (relative!='database' && relative!='media' &&
            !relative.startsWith('media/')) _unsafe();
        continue;
      }
      if (kind!=FileSystemEntityType.file) _unsafe();
      final allowed=relative=='restore-state.json' ||
          relative=='database/restored.sqlite' ||
          (relative.startsWith('media/') &&
              ModMonthVerifiedManifestV2.allowsEntryPath(relative));
      if (!allowed) _unsafe();
      if (relative=='restore-state.json') hasState=true;
      if (relative=='database/restored.sqlite') hasSqlite=true;

      final stats=await entry.stat();
      if (stats.type!=FileSystemEntityType.file || stats.size<0) _unsafe();
      records.add(relative+':'+stats.size.toString()+':'+
          stats.modified.microsecondsSinceEpoch.toString()+':'+
          stats.changed.microsecondsSinceEpoch.toString());
    }
    if (!hasState || !hasSqlite) _unsafe();
    records.sort();
    return jsonEncode(records);
  }

  /// First verify that the original location contains exactly the preview
  /// created by this operation; then move it to a private same-parent disposal
  /// directory and verify again before removing. If verification fails, leave
  /// the bytes available for inspection rather than recursively deleting them.
  static Future<void> _discard(Directory preview,String expected) async {
    final type=await FileSystemEntity.type(preview.path,followLinks:false);
    if (type==FileSystemEntityType.notFound) return;
    if (await _receipt(preview)!=expected) _unsafe();

    final quarantine=await Directory(p.dirname(preview.path))
        .createTemp('.moodiary-preview-dispose-');
    final parked=Directory(p.join(quarantine.path,'owned'));
    try {
      await preview.rename(parked.path);
      if (await _receipt(parked)!=expected) _unsafe();
      await parked.delete(recursive:true);
    } catch (_) {
      if (await FileSystemEntity.type(parked.path,followLinks:false)==
              FileSystemEntityType.directory &&
          await FileSystemEntity.type(preview.path,followLinks:false)==
              FileSystemEntityType.notFound) {
        try { await parked.rename(preview.path); } catch (_) {}
      }
      rethrow;
    } finally {
      // Non-recursive on purpose: a failed verification may leave a directory
      // or file that must never be destroyed by cleanup.
      try { await quarantine.delete(); } catch (_) {}
    }
  }

  static Future<String> install({
    required String zipPath,
    required String previewDirectory,
    required ModMonthRecoverySlotV2 slot,
    required String generationId,
    required bool Function(Diary) isTopic,
    ModMonthZipTransportV2 transport =
        const ModMonthNativeZipTransportV2(),
    Future<void> Function(String)? checkpoint,
  }) async {
    final preview=Directory(p.normalize(p.absolute(previewDirectory)));
    if (await FileSystemEntity.type(preview.path,followLinks:false)!=
        FileSystemEntityType.notFound) {
      throw const ModBundleInvalid('preview_destination_exists');
    }
    await _checkPreviewIsolation(preview,slot);
    String? receipt;
    try {
      await ModMonthIsolatedRestoreV2.restoreZipToNewIsolatedDirectory(
        zipPath:zipPath,
        outputDirectory:preview.path,
        isTopic:isTopic,
        transport:transport,
        checkpoint:checkpoint==null?null:(phase)=>checkpoint('restore:$phase'),
      );
      // The restore is now complete. Capture the actual expected files before
      // callbacks or slot install can change the preview.
      receipt=await _receipt(preview);
      await checkpoint?.call('restore:complete');
      await slot.installVerified(
        sourceDirectory:preview.path,
        generationId:generationId,
        checkpoint:checkpoint==null?null:(phase)=>checkpoint('slot:$phase'),
      );
      final selected=await slot.currentDirectory();
      if (selected==null || !selected.endsWith('/'+generationId)) {
        throw const ModBundleInvalid('generation_not_selected');
      }
      return selected;
    } finally {
      if (receipt!=null) await _discard(preview,receipt);
    }
  }
}
