import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:moodiary_mobile/app/home/mod_lan_image_decoder.dart';
import 'package:moodiary_mobile/app/home/mod_lan_image_policy.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const png1x1 =
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1Pe'
      'AAAADElEQVR4nGP4z8AAAAMBAQDJ/pLvAAAAAElFTkSuQmCC';

  late Directory root;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('moodiary-w8-codec-');
  });
  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  test('W8 verifies full PNG through real platform image codec', () async {
    final file = File(root.path + '/image.png');
    await file.writeAsBytes(base64Decode(png1x1));
    await expectLater(modLanVerifyDecodedImage(file, 'image/png'), completes);
  });

  test('W8 refuses a truncated image body even with valid PNG header',
      () async {
    final data = base64Decode(png1x1);
    final file = File(root.path + '/broken.png');
    await file.writeAsBytes(data.sublist(0, 30));
    await expectLater(
      modLanVerifyDecodedImage(file, 'image/png'),
      throwsA(isA<ModLanImagePolicyException>()
          .having((e) => e.code, 'code', 'image_decode_failed')),
    );
  });

  test('W8 refuses missing file on real decoder', () async {
    final file = File(root.path + '/missing.png');
    await expectLater(
      modLanVerifyDecodedImage(file, 'image/png'),
      throwsA(isA<ModLanImagePolicyException>()),
    );
  });
}
