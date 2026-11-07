import '../overlay/mobile/lib/app/home/mod_lan_image_policy.dart';

void check(bool test, String message) {
  if (!test) throw StateError('W8 failed: $message');
}

void denies(void Function() run, int status, String code) {
  try {
    run();
  } on ModLanImagePolicyException catch (error) {
    check(error.status == status && error.code == code,
        'unexpected $error, expected $status/$code');
    return;
  }
  throw StateError('W8 expected $status/$code exception');
}

List<int> pngHeader({int width = 800, int height = 600}) {
  final bytes = <int>[0x89, 0x50, 0x4e, 0x47, 13, 10, 26, 10,
    0, 0, 0, 13, 0x49, 0x48, 0x44, 0x52];
  for (final value in [width, height]) {
    bytes.addAll([
      (value >> 24) & 255, (value >> 16) & 255,
      (value >> 8) & 255, value & 255,
    ]);
  }
  return [...bytes, ...List<int>.filled(40, 0)];
}

List<int> webpHeader() =>
  [0x52, 0x49, 0x46, 0x46, 0x14, 0, 0, 0,
    0x57, 0x45, 0x42, 0x50,
    0x56, 0x50, 0x38, 0x58, ...List<int>.filled(40, 0)];

void main() {
  check(ModLanImagePolicy.declaredType('Image/PNG; charset=binary')
          == 'image/png', 'normalizes declared MIME');
  denies(() => ModLanImagePolicy.declaredType('image/svg+xml'),
    415, 'image_type_not_allowed');
  denies(() => ModLanImagePolicy.declaredType('text/html'),
    415, 'image_type_not_allowed');
  denies(() => ModLanImagePolicy.declaredLength(null),
    411, 'image_length_required');
  denies(() => ModLanImagePolicy.declaredLength(0),
    422, 'image_empty');
  denies(() => ModLanImagePolicy.declaredLength(20 * 1024 * 1024 + 1),
    413, 'image_too_large');

  // A binary signature must be grounded in content, not in filename.
  final jpeg = <int>[0xff, 0xd8, 0xff, 0xe0, ...List<int>.filled(60, 0)];
  check(ModLanImagePolicy.identify(jpeg) == 'image/jpeg', 'sniffs JPEG');
  check(ModLanImagePolicy.identify(pngHeader()) == 'image/png', 'sniffs PNG');
  check(ModLanImagePolicy.identify(webpHeader()) == 'image/webp', 'sniffs WebP');
  check(ModLanImagePolicy.identify([0x4d,0x5a,0x90,0x00]) == null,
      'rejects disguised executable');
  denies(() => ModLanImagePolicy.checkImageHeader(pngHeader(), 'image/jpeg'),
      415, 'image_signature_mismatch');
  denies(() => ModLanImagePolicy.checkImageHeader(pngHeader(width:0),
      'image/png'), 422, 'image_dimensions_invalid');
  denies(() => ModLanImagePolicy.checkImageHeader(
      pngHeader(width:12000,height:12000), 'image/png'),
      422, 'image_dimensions_invalid');

  // Chunks do not need to arrive on byte/record boundaries.
  final valid = ModLanImageIntake(
      contentType:'image/png', contentLength:pngHeader().length);
  final bytes = pngHeader();
  valid.addChunk(bytes.sublist(0,4));
  valid.addChunk(bytes.sublist(4,21));
  valid.addChunk(bytes.sublist(21));
  valid.finish();
  check(valid.received == bytes.length, 'valid split PNG');

  final incomplete = ModLanImageIntake(
      contentType:'image/jpeg',contentLength:jpeg.length);
  incomplete.addChunk(jpeg.sublist(0, jpeg.length - 1));
  denies(incomplete.finish, 422, 'image_incomplete');

  final overflow = ModLanImageIntake(
      contentType:'image/jpeg',contentLength:jpeg.length);
  overflow.addChunk(jpeg);
  denies(() => overflow.addChunk([1]), 413, 'image_length_exceeded');

  final disguised = ModLanImageIntake(
      contentType:'image/png',contentLength:jpeg.length);
  disguised.addChunk(jpeg);
  denies(disguised.finish, 415, 'image_signature_mismatch');
  print('W8 standalone LAN image policy tests passed');
}
