// W8.3 Android/Flutter decode gate for already size- and signature-checked
// LAN images. Call on the platform UI engine/isolate, not a pure Dart isolate.
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'mod_lan_image_policy.dart';

/// Validate actual decoded dimensions and a real frame before considering
/// this image eligible for native MediaManager storage.
///
/// Deliberately down-samples during verification to avoid unnecessarily
/// materializing full-resolution pixels in the upload pipeline.
Future<void> modLanVerifyDecodedImage(File file, String mime) async {
  ui.ImmutableBuffer? buffer;
  ui.ImageDescriptor? descriptor;
  ui.Codec? codec;
  ui.Image? decoded;
  try {
    buffer = await ui.ImmutableBuffer.fromFilePath(file.path);
    descriptor = await ui.ImageDescriptor.encoded(buffer);
    final width = descriptor.width;
    final height = descriptor.height;
    if (width < 1 || height < 1 ||
        width > 32000 || height > 32000 ||
        width * height > ModLanImagePolicy.maxPixels) {
      throw const ModLanImagePolicyException(
        422, 'image_dimensions_invalid');
    }

    // The initial magic-number gate has already checked declared MIME.
    // Native decoders are the final authority for malformed image bodies.
    codec = await descriptor.instantiateCodec(
      targetWidth: math.min(width, 192),
      targetHeight: math.min(height, 192),
    );
    final frame = await codec.getNextFrame();
    decoded = frame.image;
    if (decoded.width < 1 || decoded.height < 1) {
      throw const ModLanImagePolicyException(422, 'image_decode_failed');
    }
  } on ModLanImagePolicyException {
    rethrow;
  } catch (_) {
    throw const ModLanImagePolicyException(422, 'image_decode_failed');
  } finally {
    decoded?.dispose();
    codec?.dispose();
    descriptor?.dispose();
    buffer?.dispose();
  }
}
