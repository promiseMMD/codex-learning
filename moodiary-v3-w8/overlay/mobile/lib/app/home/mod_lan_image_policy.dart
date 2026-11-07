/// W8 untrusted LAN picture intake policy.
 ///
 /// This is intentionally independent of MediaManager and of the HTTP server:
 /// it validates a stream before MediaManager.saveImage is ever called.
 /// MIME signatures alone do not establish that an image fully decodes.
 /// Callers MUST finish with an actual image decode, a temporary file,
 /// atomic attachment linking and cleanup on failure.
class ModLanImagePolicyException implements Exception {
  final int status;
  final String code;
  const ModLanImagePolicyException(this.status, this.code);

  @override
  String toString() => 'ModLanImagePolicyException($status, $code)';
}

class ModLanImagePolicy {
  static const int maxBytes = 20 * 1024 * 1024;
  static const int maxPixels = 60 * 1000 * 1000;
  static const int _headerBudget = 64;
  static const Set<String> allowedMimeTypes = {
    'image/jpeg', 'image/png', 'image/webp',
  };

  static Never _deny(int status, String code) =>
      throw ModLanImagePolicyException(status, code);

  /// Normalizes MIME parameter suffixes (e.g. image/png; charset=binary).
  /// Unknown or forged image MIME types are rejected, not trusted.
  static String declaredType(String value) {
    final type = value.split(';').first.trim().toLowerCase();
    if (!allowedMimeTypes.contains(type)) _deny(415, 'image_type_not_allowed');
    return type;
  }

  /// First version requires Content-Length to avoid unlimited anonymous
  /// chunked uploads. The streaming counter checks the actual byte count.
  static int declaredLength(int? contentLength) {
    if (contentLength == null) _deny(411, 'image_length_required');
    if (contentLength <= 0) _deny(422, 'image_empty');
    if (contentLength > maxBytes) _deny(413, 'image_too_large');
    return contentLength;
  }

  static int _u32be(List<int> bytes, int i) =>
      ((bytes[i] & 255) << 24) |
      ((bytes[i + 1] & 255) << 16) |
      ((bytes[i + 2] & 255) << 8) |
      (bytes[i + 3] & 255);

  static int _u32le(List<int> bytes, int i) =>
      ((bytes[i + 3] & 255) << 24) |
      ((bytes[i + 2] & 255) << 16) |
      ((bytes[i + 1] & 255) << 8) |
      (bytes[i] & 255);

  static bool _ascii(List<int> data, int start, String token) =>
      data.length >= start + token.length &&
      List.generate(token.length, (i) => data[start + i])
          .every((element) => element >= 0 && element <= 127) &&
      String.fromCharCodes(data.sublist(start, start + token.length)) == token;

  /// Checks only primary file signatures, never extension or filename.
  static String? identify(List<int> header) {
    if (header.length >= 3 &&
        header[0] == 0xff && header[1] == 0xd8 && header[2] == 0xff) {
      return 'image/jpeg';
    }
    if (header.length >= 24 &&
        header[0] == 0x89 && _ascii(header, 1, 'PNG') &&
        header[4] == 13 && header[5] == 10 &&
        header[6] == 26 && header[7] == 10 &&
        _u32be(header, 8) == 13 && _ascii(header, 12, 'IHDR')) {
      return 'image/png';
    }
    if (header.length >= 20 && _ascii(header, 0, 'RIFF') &&
        _ascii(header, 8, 'WEBP') &&
        (_ascii(header, 12, 'VP8 ') ||
         _ascii(header, 12, 'VP8L') ||
         _ascii(header, 12, 'VP8X'))) {
      // RIFF chunk size is fileSize - 8.
      final riffBytes = _u32le(header, 4) + 8;
      if (riffBytes < 20) return null;
      return 'image/webp';
    }
    return null;
  }

  static void checkImageHeader(List<int> header, String declaredMime) {
    final detected = identify(header);
    if (detected == null || detected != declaredMime) {
      _deny(415, 'image_signature_mismatch');
    }

    if (detected == 'image/png') {
      final width = _u32be(header, 16);
      final height = _u32be(header, 20);
      if (width <= 0 || height <= 0 ||
          width > 32000 || height > 32000 ||
          width * height > maxPixels) {
        _deny(422, 'image_dimensions_invalid');
      }
    }
  }

  static const int headerBudget = _headerBudget;
}

/// Mutable byte counter to be attached to the incoming request stream.
/// Keeps at most the first 64 bytes in memory (no whole-file buffering).
///
/// User-facing intake MUST write chunks to an isolated temp file, and run
/// decode/dimensions/hash checks before moving them into permanent storage.
class ModLanImageIntake {
  final String declaredMime;
  final int expectedLength;
  int _received = 0;
  final List<int> _prefix = [];

  ModLanImageIntake({
    required String contentType,
    required int? contentLength,
  }) : declaredMime = ModLanImagePolicy.declaredType(contentType),
       expectedLength = ModLanImagePolicy.declaredLength(contentLength);

  int get received => _received;

  void addChunk(List<int> chunk) {
    if (chunk.isEmpty) return;
    if (chunk.length > ModLanImagePolicy.maxBytes - _received ||
        chunk.length > expectedLength - _received) {
      throw const ModLanImagePolicyException(413, 'image_length_exceeded');
    }
    final free = ModLanImagePolicy.headerBudget - _prefix.length;
    if (free > 0) {
      _prefix.addAll(chunk.take(free));
    }
    _received += chunk.length;
  }

  void finish() {
    if (_received != expectedLength) {
      throw const ModLanImagePolicyException(422, 'image_incomplete');
    }
    ModLanImagePolicy.checkImageHeader(_prefix, declaredMime);
  }
}
