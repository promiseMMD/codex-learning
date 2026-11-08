import 'dart:io';

import 'package:moodiary_models/moodiary_models.dart';

import 'mod_month_isolated_restore_v2.dart';
import 'mod_month_recovery_slot_v2.dart';
import 'mod_month_verified_manifest_v1.dart' show ModBundleInvalid;
import 'mod_month_zip_bundle_v2.dart';

/// W9.8.4.4: end-to-end ZIP -> cold V2 restore -> immutable V2 generation.
///
/// The temporary cold-restore directory is deleted after the slot has
/// independently copied and verified it. The slot remains isolated from
/// every live application database and media directory.
final class ModMonthZipGenerationInstallV2 {
  const ModMonthZipGenerationInstallV2._();

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
    final preview=Directory(previewDirectory);
    if (await FileSystemEntity.type(preview.path,followLinks:false)!=
        FileSystemEntityType.notFound) {
      throw const ModBundleInvalid('preview_destination_exists');
    }
    var restored=false;
    try {
      await ModMonthIsolatedRestoreV2.restoreZipToNewIsolatedDirectory(
        zipPath:zipPath,
        outputDirectory:preview.path,
        isTopic:isTopic,
        transport:transport,
        checkpoint:checkpoint==null?null:(phase)=>checkpoint('restore:$phase'),
      );
      restored=true;
      await checkpoint?.call('restore:complete');
      await slot.installVerified(
        sourceDirectory:preview.path,
        generationId:generationId,
        checkpoint:checkpoint==null?null:
          (phase)=>checkpoint('slot:$phase'),
      );
      final selected=await slot.currentDirectory();
      if (selected==null || !selected.endsWith('/'+generationId)) {
        throw const ModBundleInvalid('generation_not_selected');
      }
      return selected;
    } finally {
      if (restored && await preview.exists()) {
        await preview.delete(recursive:true);
      }
    }
  }
}
