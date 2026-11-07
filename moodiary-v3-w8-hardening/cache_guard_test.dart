import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:moodiary_files/moodiary_files.dart';

void main() {
  test('W8.5.1 cache clear preserves active LAN upload staging', () async {
    final temp = await Directory.systemTemp.createTemp('moodiary-w8-safe-');
    try {
      final uploadRoot = await Directory(
        temp.path + '/moodiary-v3-lan-stage/pending-upload',
      ).create(recursive: true);
      final staged = File(uploadRoot.path + '/image');
      await staged.writeAsBytes([0x89, 0x50, 0x4e, 0x47]);

      final ordinary = File(temp.path + '/stale.cache');
      await ordinary.writeAsBytes([1, 2, 3, 4]);

      expect(AppFiles.isProtectedCacheEntry('moodiary-v3-lan-stage'), isTrue);
      expect(AppFiles.isProtectedCacheEntry('stale.cache'), isFalse);

      final freed = await AppFiles.clearCache(cachePath: temp.path);
      expect(freed, 4);
      expect(await staged.exists(), isTrue,
          reason: 'in-flight image must survive ordinary cache cleanup');
      expect(await ordinary.exists(), isFalse,
          reason: 'ordinary cache must still be reclaimable');
    } finally {
      await temp.delete(recursive: true);
    }
  });

  test('W8.5.1 special staging protection is exact, not a broad prefix', () {
    expect(AppFiles.isProtectedCacheEntry('moodiary-v3-lan-stage'), true);
    expect(AppFiles.isProtectedCacheEntry('moodiary-v3-lan-stage-old'), false);
    expect(AppFiles.isProtectedCacheEntry('moodiary-v3-lan-stage-evil'), false);
  });
}
