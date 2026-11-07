// W8.5 single-image attach transaction with compensation.
// This module is server-side only. The browser never supplies a permanent
// image filename or modifies the diary JSON to insert unverified media.
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:moodiary_data/moodiary_data.dart';
import 'package:moodiary_files/moodiary_files.dart';
import 'package:moodiary_models/moodiary_models.dart';
import 'package:moodiary_utils/moodiary_utils.dart';

import 'mod_lan_image_policy.dart';
import 'mod_lan_image_staging.dart';
import 'mod_lan_rich.dart';
import 'mod_lan_write.dart';

typedef ModLanPromoteImage = Future<String> Function(
  ModLanStagedImage staged,
);
typedef ModLanImageFile = File Function(String name);
typedef ModLanDeleteImage = Future<void> Function(String name);

class ModLanImageAttach {
  final DiaryRepository repository;
  final ModLanImageStaging staging;
  final ModLanPromoteImage promoteImage;
  final ModLanImageFile fileForImage;
  final ModLanDeleteImage deleteImage;
  final bool Function() isSessionActive;

  ModLanImageAttach({
    required this.repository,
    required this.staging,
    ModLanPromoteImage? promoteImage,
    ModLanImageFile? fileForImage,
    ModLanDeleteImage? deleteImage,
    bool Function()? isSessionActive,
  }) : isSessionActive = isSessionActive ?? (() => true),
       promoteImage = promoteImage ?? _nativePromote,
       fileForImage = fileForImage ??
           ((name) => File(AppFiles.getRealPath('image', name))),
       deleteImage = deleteImage ?? AppFiles.deleteImage;

  static Future<String> _nativePromote(ModLanStagedImage staged) async {
    // Explicitly disable src-name reuse. Only the platform MediaManager
    // allocates permanent media names.
    final name = await MediaManager.saveImage(
      XFile(staged.file.path, mimeType: staged.mime),
      reuseExisting: false,
    );
    if (name == null) {
      throw const ModLanImagePolicyException(500, 'image_promote_failed');
    }
    return name;
  }

  static const _idPattern = r'^[a-f0-9]{48}$';
  static const _revisionPattern = r'^[a-f0-9]{64}$';
  static const _imageNamePattern =
      r'^image-[0-9a-zA-Z-]{8,100}\.(jpg|jpeg|png|webp)$';

  static String _requiredString(Object? value, String pattern, String code) {
    if (value is! String || !RegExp(pattern).hasMatch(value)) {
      throw ModLanImagePolicyException(422, code);
    }
    return value;
  }

  /// Attaches ONE staged image at the end of a simple supported rich diary.
  ///
  /// The operation rejects complex/media diaries because W7's present editor
  /// cannot roundtrip their nodes. Later, W8.6 must implement full image
  /// round-trip before enabling arbitrary cursor-position insertion.
  ///
  /// The file is first promoted and SHA-256-verified, then attached with
  /// database CAS. When the database write fails, the unique new image is
  /// deleted as compensation. No claim of ACID across filesystem and DB.
  Future<Diary> appendStagedImage({
    required String diaryId,
    required String stageId,
    required String ownerSession,
    required String revision,
  }) async {
    final safeDiaryId = ModLanWriteSafety.id(diaryId);
    final safeStageId = _requiredString(
      stageId, _idPattern, 'invalid_staging_id',
    );
    _requiredString(revision, _revisionPattern, 'invalid_revision');

    if (!isSessionActive()) {
      throw const ModLanImagePolicyException(403, 'session_revoked');
    }
    if (ownerSession.isEmpty) {
      throw const ModLanImagePolicyException(401, 'pairing_required');
    }

    return staging.consumeWith<Diary>(
      id: safeStageId,
      ownerSession: ownerSession,
      commit: (staged) async {
        if (!isSessionActive()) {
          throw const ModLanImagePolicyException(403, 'session_revoked');
        }
        // Read and validate BEFORE making a permanent media file.
        final previous = await repository.getDiaryByBusinessId(safeDiaryId);
        if (previous == null || !previous.show) {
          throw const ModLanWriteException(404, 'diary_not_found');
        }
        if (!ModLanRichDocument.canEdit(previous)) {
          throw const ModLanWriteException(409, 'rich_diary_read_only');
        }
        if (ModLanWriteSafety.revision(previous) != revision) {
          throw const ModLanWriteException(409, 'stale_revision');
        }
        if (!await staged.file.exists() ||
            await staged.file.length() != staged.size) {
          throw const ModLanImagePolicyException(422, 'staged_image_changed');
        }

        String? savedName;
        bool diaryCommitted = false;
        try {
          savedName = await promoteImage(staged);
          if (!RegExp(_imageNamePattern).hasMatch(savedName)) {
            // Refuse to resolve any attacker-supplied media path.
            throw const ModLanImagePolicyException(
              500, 'invalid_native_image_name',
            );
          }
          final savedFile = fileForImage(savedName);
          if (!await savedFile.exists() ||
              await savedFile.length() != staged.size ||
              (await sha256.bind(savedFile.openRead()).first).toString() !=
                  staged.sha256Hex) {
            throw const ModLanImagePolicyException(
              500, 'image_promote_integrity_failed',
            );
          }

          // Construct the image node on the PHONE, not from browser input.
          // Matches Moodiary's native Tiptap image node attributes.
          final originalDoc = jsonDecode(previous.content);
          if (originalDoc is! Map<String, dynamic> ||
              originalDoc['content'] is! List) {
            throw const ModLanWriteException(409, 'rich_diary_read_only');
          }
          final blocks = List<dynamic>.of(originalDoc['content'] as List);
          blocks.add({
            'type': 'image',
            'attrs': {
              'src': savedName,
              'name': null,
              'widthPercent': null,
            },
          });
          final nextContent = jsonEncode({
            ...originalDoc,
            'content': blocks,
          });
          final next = withDerivedMedia(
            previous.copyWith(
              content: nextContent,
              contentText: TiptapContent.parse(nextContent).plainText,
              lastModified: DateTime.now().toUtc(),
            ),
          );
          if (!next.imageName.contains(savedName)) {
            throw const ModLanImagePolicyException(
              500, 'native_media_reference_missing',
            );
          }

          if (!isSessionActive()) {
            throw const ModLanImagePolicyException(403, 'session_revoked');
          }
          // The repo operation checks a full expected snapshot in a SQLite
          // transaction. Another phone/PC edit must result in 409, not LWW.
          final ok = await repository.updateADiaryIfCurrent(
            newDiary: next,
            expectedSnapshot: previous,
          );
          if (!ok) {
            throw const ModLanWriteException(409, 'stale_revision');
          }
          diaryCommitted = true;
          return (await repository.getDiaryByBusinessId(safeDiaryId)) ?? next;
        } catch (error) {
          if (savedName != null && !diaryCommitted &&
              RegExp(_imageNamePattern).hasMatch(savedName)) {
            try {
              await deleteImage(savedName);
            } catch (_) {
              // The file may be orphaned; NEVER report success or claim
              // cleanup succeeded. Native orphan scan on subsequent app
              // startup is a separate, mandatory recovery gate.
              throw const ModLanImagePolicyException(
                500, 'orphan_cleanup_failed',
              );
            }
          }
          rethrow;
        }
      },
    );
  }
}
