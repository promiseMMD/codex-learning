import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moodiary_data/moodiary_data.dart';
import 'package:moodiary_di/moodiary_di.dart';
import 'package:moodiary_sync/src/data/codec.dart';
import 'package:moodiary_sync/src/data/impl/local_archive.dart';
import 'package:moodiary_sync/src/data/incremental_engine.dart';
import 'package:moodiary_sync/src/data/sync_logger.dart';
import 'package:moodiary_sync/src/data/sync_stores.dart';
import '../sync_test_harness.dart';

void main() {
  late MoodiaryDatabase db;
  late SyncLogger logger;
  setUp(() async {
    logger = (await setUpSyncEnv()).logger;
    db = MoodiaryDatabase.forTesting(NativeDatabase.memory());
    getIt.registerSingleton<MoodiaryDatabase>(db);
    await db.customSelect('SELECT 1').get();
  });
  tearDown(() async {
    await db.close();
    await tearDownSyncEnv();
  });

  Future<void> seedMonth() => db.customStatement(
    'INSERT INTO mod_month_pages(topic_id,month_key,diary_id,created_ms) '
    'VALUES(?,?,NULL,?)', ['test-topic', '2026-11', 10]);

  test('real push/pull/sync fail before reading or writing remote', () async {
    await seedMonth();
    final remote = FakeRemoteBackend();
    final engine = IncrementalSyncEngine(remote, logger: logger,
      diaryStore: RepoSyncDiaryStore(),
      categoryStore: FakeCategoryStore(), placeStore: FakePlaceStore(),
      tombstoneStore: FakeTombstoneStore(), mediaFiles: FakeMediaFiles(),
      cipherProvider: () async => SyncCipher.plaintext);
    await expectLater(engine.push(), throwsA(isA<ModMonthArchiveBlocked>()));
    await expectLater(engine.pull(), throwsA(isA<ModMonthArchiveBlocked>()));
    await expectLater(engine.sync(), throwsA(isA<ModMonthArchiveBlocked>()));
    expect(remote.ops, isEmpty);
    expect(remote.objects, isEmpty);
  });

  test('legacy ZIP export and import are blocked before filesystem writes', () async {
    await seedMonth();
    await expectLater(LocalArchive.export(), throwsA(isA<ModMonthArchiveBlocked>()));
    await expectLater(LocalArchive.import('missing.zip'), throwsA(isA<ModMonthArchiveBlocked>()));
  });

  test('isolated fake-store sync regression remains runnable', () async {
    await seedMonth();
    final remote = FakeRemoteBackend();
    final engine = IncrementalSyncEngine(remote, logger: logger,
      diaryStore: FakeDiaryStore(), categoryStore: FakeCategoryStore(),
      placeStore: FakePlaceStore(), tombstoneStore: FakeTombstoneStore(),
      mediaFiles: FakeMediaFiles(),
      cipherProvider: () async => SyncCipher.plaintext);
    expect((await engine.push()).failed, 0);
  });
}
