import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:moodiary_sync/src/data/mod_month_android_restore_root_v2.dart';
import 'package:moodiary_sync/src/data/mod_month_verified_manifest_v1.dart'
    show ModBundleInvalid;

void main() {
  late Directory sandbox;

  setUp(() {
    sandbox = Directory.systemTemp.createTempSync('android-restore-root-read-');
  });

  tearDown(() {
    sandbox.deleteSync(recursive: true);
  });

  test(
    'Android private root inspection returns null without creating a missing root',
    () async {
      final root = await ModMonthPrivateRestoreRootV2.openExistingIfPresentForSupport(
        applicationSupportDirectory: sandbox.path,
      );
      expect(root, isNull);
      expect(
        await Directory(
          '${sandbox.path}/${ModMonthPrivateRestoreRootV2.directoryName}',
        ).exists(),
        isFalse,
      );
    },
  );

  test(
    'Android private root inspection opens an existing verified root only',
    () async {
      final created = await ModMonthPrivateRestoreRootV2.createOrOpenForSupport(
        applicationSupportDirectory: sandbox.path,
      );
      final inspected =
          await ModMonthPrivateRestoreRootV2.openExistingIfPresentForSupport(
        applicationSupportDirectory: sandbox.path,
      );
      expect(inspected?.root, created.root);
      expect(inspected?.applicationSupportDirectory, sandbox.path);
    },
  );

  test(
    'Android private root inspection rejects a symlink without following it',
    () async {
      final target = Directory('${sandbox.path}/user-data');
      await target.create();
      final note = File('${target.path}/keep.txt');
      await note.writeAsString('preserve-me', flush: true);
      final link = Link(
        '${sandbox.path}/${ModMonthPrivateRestoreRootV2.directoryName}',
      );
      await link.create(target.path);

      await expectLater(
        ModMonthPrivateRestoreRootV2.openExistingIfPresentForSupport(
          applicationSupportDirectory: sandbox.path,
        ),
        throwsA(isA<ModBundleInvalid>()),
      );
      expect(await note.readAsString(), 'preserve-me');
      expect(
        await FileSystemEntity.type(link.path, followLinks: false),
        FileSystemEntityType.link,
      );
    },
  );
}
