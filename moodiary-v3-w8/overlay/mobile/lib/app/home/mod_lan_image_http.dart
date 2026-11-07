// W8.4 authorized upload transport. The caller MUST authenticate the
// session, verify same-origin and X-Moodiary-CSRF before invoking this method.
//
// This only stages image bytes in an application-private temp directory.
// It NEVER links media to a Diary or reports WebDAV sync success.
import 'dart:async';
import 'dart:io';

import 'mod_lan_image_policy.dart';
import 'mod_lan_image_staging.dart';

class ModLanImageHttp {
  static const uploadTimeout = Duration(seconds: 90);

  static Future<ModLanStagedImage> accept({
    required HttpRequest request,
    required String authorizedSessionId,
    required ModLanImageStaging staging,
  }) async {
    if (authorizedSessionId.isEmpty) {
      throw const ModLanImagePolicyException(401, 'pairing_required');
    }
    // Do not allow decompression at HTTP middleware level to change the
    // meaning of Content-Length or allow a gzip-compression bomb.
    final encoding = request.headers.value(HttpHeaders.contentEncodingHeader);
    if (encoding != null && encoding.toLowerCase() != 'identity') {
      throw const ModLanImagePolicyException(
        415, 'image_content_encoding_not_allowed');
    }
    final length = request.headers.contentLength;
    if (length < 0) {
      throw const ModLanImagePolicyException(411, 'image_length_required');
    }
    final mime = request.headers.contentType?.mimeType ?? '';
    return staging.accept(
      ownerSession: authorizedSessionId,
      contentType: mime,
      contentLength: length,
      body: request.timeout(
        uploadTimeout,
        onTimeout: (sink) => sink.addError(
          const ModLanImagePolicyException(408, 'image_upload_timeout'),
        ),
      ),
    );
  }
}
