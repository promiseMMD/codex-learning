import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/drift.dart' show Variable;
import 'package:drift/native.dart';
import 'package:moodiary_data/moodiary_data.dart';
import 'package:moodiary_di/moodiary_di.dart';
import 'package:moodiary_models/moodiary_models.dart';
import 'package:moodiary_sync/src/data/model/manifest.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moodiary_sync/src/data/archive_apply.dart';
import 'package:moodiary_sync/src/data/codec.dart';
import 'package:moodiary_sync/src/data/impl/local_archive.dart';
import 'package:moodiary_sync/src/data/sync_stores.dart';
import 'package:path/path.dart' as p;

import '../../../lib/src/data/mod_month_full_backup_archive_v1.dart';
import '../../../lib/src/data/mod_month_zip_preflight_v2.dart';
import '../../../lib/src/data/mod_month_verified_manifest_v1.dart';


import '../sync_test_harness.dart';

/// Writes the exact upstream LocalArchive export entries without Rust in tests.
final class _OriginalDirectorySink implements ArchiveSink {
  final String directory;
  const _OriginalDirectorySink(this.directory);

  @override
  Future<void> addBytes(String name, Uint8List bytes) async {
    final file = File(p.join(directory, name));
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes);
  }

  @override
  Future<void> addLocalFile(String name, String source) async {
    final file = File(p.join(directory, name));
    await file.parent.create(recursive: true);
    await File(source).copy(file.path);
  }

  @override
  Future<void> finish() async {}
}

void main() {
  late Directory sandbox;

  setUp(() async {
    sandbox = await Directory.systemTemp.createTemp('moodiary-legacy-zip-');
  });

  tearDown(() async {
    if (await sandbox.exists()) await sandbox.delete(recursive: true);
  });

  Future<String> makeZip(List<String> entries) async {
    final output = '${sandbox.path}${Platform.pathSeparator}fixture.zip';
    // Creates a real standards-compliant ZIP central directory, without
    // involving Rust media assets or touching any user's private files.
    final result = await Process.run('python3', [
      '-c',
      r"""
import sys, zipfile
with zipfile.ZipFile(sys.argv[1], 'w', compression=zipfile.ZIP_STORED) as archive:
    for name in sys.argv[2:]:
        archive.writestr(name, '{}')
""",
      output,
      ...entries,
    ]);
    expect(result.exitCode, 0, reason: result.stderr.toString());
    return output;
  }

  test('production full-backup service compiles with release API', () {
    const error = ModMonthFullBackupException('expected_failure');
    expect(error.code, 'expected_failure');
    expect(error.toString(), contains('expected_failure'));
    expect(ModMonthFullBackupArchiveV1, isNotNull);
  });

  test('ordinary backup remains in original restore branch', () {
    expect(
      ModMonthZipPreflightV2.hasCompleteFullHistoryMarkers(
        const ['manifest.json', 'diary/sample.json'],
      ),
      isFalse,
    );
  });

  test('complete history archive uses full migration branch', () {
    expect(
      ModMonthZipPreflightV2.hasCompleteFullHistoryMarkers(const [
        'manifest.json',
        'structured/month-day-graph-v2.json',
        'verified-day-bundle-v2.json',
      ]),
      isTrue,
    );
  });

  test('one history marker cannot downgrade to a partial import', () {
    for (final path in [
      'structured/month-day-graph-v2.json',
      'verified-day-bundle-v2.json',
    ]) {
      expect(
        () => ModMonthZipPreflightV2.hasCompleteFullHistoryMarkers(
          ['manifest.json', path],
        ),
        throwsA(
          isA<ModBundleInvalid>().having(
            (e) => e.code,
            'code',
            'incomplete_full_history_markers',
          ),
        ),
      );
    }
  });
  test('real legacy ordinary ZIP routes to unchanged native restore', () async {
    final file = await makeZip(const [
      'manifest.json',
      'diary/sample.json',
      'category/sample.json',
      'media/image/keep.png',
    ]);
    final names = await ModMonthZipPreflightV2.inspectForBackupRouting(file);
    expect(names, containsAll(const [
      'manifest.json',
      'diary/sample.json',
      'category/sample.json',
      'media/image/keep.png',
    ]));
    expect(ModMonthZipPreflightV2.hasCompleteFullHistoryMarkers(names), isFalse);
  });

  test('real full-history ZIP is routed to strict V2 validation', () async {
    final file = await makeZip(const [
      'manifest.json',
      'diary/sample.json',
      'structured/month-day-graph-v2.json',
      'verified-day-bundle-v2.json',
    ]);
    final names = await ModMonthZipPreflightV2.inspectForBackupRouting(file);
    expect(ModMonthZipPreflightV2.hasCompleteFullHistoryMarkers(names), isTrue);
    // This is only routing; the actual importer must still verify every
    // manifest, file hash, revision and operation before writing live data.
  });

  test('real incomplete-history ZIP never silently falls back', () async {
    final file = await makeZip(const [
      'manifest.json',
      'structured/month-day-graph-v2.json',
    ]);
    final names = await ModMonthZipPreflightV2.inspectForBackupRouting(file);
    expect(
      () => ModMonthZipPreflightV2.hasCompleteFullHistoryMarkers(names),
      throwsA(isA<ModBundleInvalid>().having(
        (e) => e.code, 'code', 'incomplete_full_history_markers',
      )),
    );
  });

  test('unsafe ZIP entry is rejected before a restore is selected', () async {
    final file = await makeZip(const [
      'manifest.json',
      '../outside.txt',
    ]);
    await expectLater(
      ModMonthZipPreflightV2.inspectForBackupRouting(file),
      throwsA(isA<ModBundleInvalid>().having(
        (e) => e.code, 'code', 'unsafe_or_duplicate_zip_entry',
      )),
    );
  });

  test('truncated ZIP is rejected before any restore', () async {
    final file = File('${sandbox.path}${Platform.pathSeparator}truncated.zip');
    await file.writeAsBytes([80, 75, 3, 4], flush: true);
    await expectLater(
      ModMonthZipPreflightV2.inspectForBackupRouting(file.path),
      throwsA(isA<ModBundleInvalid>().having(
        (e) => e.code, 'code', 'zip_truncated',
      )),
    );
  });

  test('resume: only source-owned native rows can survive an interrupted import', () async {
    final db = MoodiaryDatabase.forTesting(NativeDatabase.memory());
    try {
      await db.customSelect('SELECT 1').get();
      final graph = await ModMonthGraphArchiveV2.exportGraph(db);
      final manifest = SyncManifest(
        version: SyncManifest.currentVersion,
        updatedAtMs: 10,
        entries: {
          SyncKeys.diary('expected-diary'): const ManifestEntry(timeMs: 200),
        },
      );
      Future<void> check(String phase) =>
          ModMonthFullBackupArchiveV1.validateResumeTarget(
            db: db, manifest: manifest, graph: graph, phase: phase,
          );
      // A crash directly after creating the journal can leave an empty DB.
      await check('verified');
      await expectLater(check('native_imported'),
          throwsA(isA<ModMonthFullBackupException>().having(
            (e) => e.code, 'code', 'migration_resume_native_mismatch')));
      await db.customStatement(
        'INSERT INTO diaries '
        '(id,title,content,content_text,time,last_modified,show,type) '
        'VALUES(?,?,?,?,?,?,?,?)',
        ['expected-diary', 'safe', 'safe', 'safe', 100, 200000, 1, 'tiptap'],
      );
      // A crash mid-native-import is recoverable only for source-owned rows.
      await check('verified');
      await check('native_imported');
      await check('graph_imported');
      await db.customStatement(
        'INSERT INTO diaries '
        '(id,title,content,content_text,time,last_modified,show,type) '
        'VALUES(?,?,?,?,?,?,?,?)',
        ['unrelated-diary', 'keep', 'keep', 'keep', 100, 200000, 1, 'tiptap'],
      );
      await expectLater(check('verified'),
          throwsA(isA<ModMonthFullBackupException>().having(
            (e) => e.code, 'code', 'migration_resume_native_mismatch')));
      // The failed guard must not modify an unrelated diary.
      final retained = await db.customSelect(
        'SELECT content FROM diaries WHERE id=?',
        variables: [Variable.withString('unrelated-diary')],
      ).getSingle();
      expect(retained.read<String>('content'), 'keep');
    } finally {
      await db.close();
    }
  });

  test('resume refuses timestamp mismatch, alien tombstone, and partial W9 graph', () async {
    final db = MoodiaryDatabase.forTesting(NativeDatabase.memory());
    try {
      await db.customSelect('SELECT 1').get();
      final graph = await ModMonthGraphArchiveV2.exportGraph(db);
      final manifest = SyncManifest(
        version: SyncManifest.currentVersion,
        updatedAtMs: 10,
        entries: {
          SyncKeys.diary('expected-diary'): const ManifestEntry(timeMs: 200),
        },
      );
      Future<void> check() =>
          ModMonthFullBackupArchiveV1.validateResumeTarget(
            db: db, manifest: manifest, graph: graph, phase: 'verified',
          );
      await db.customStatement(
        'INSERT INTO diaries '
        '(id,title,content,content_text,time,last_modified,show,type) '
        'VALUES(?,?,?,?,?,?,?,?)',
        ['expected-diary', 'same-id', 'different', 'different', 100, 201000, 1, 'tiptap'],
      );
      await expectLater(check(), throwsA(isA<ModMonthFullBackupException>()
          .having((e) => e.code, 'code', 'migration_resume_native_mismatch')));
      await db.customStatement(
        'UPDATE diaries SET last_modified=? WHERE id=?',
        [200000, 'expected-diary'],
      );
      await check();
      await TombstoneRepository(db).putAll([
        SyncTombstone(
          key: SyncKeys.diary('alien-deleted'),
          timeMs: 300, pushedBackends: const [],
        ),
      ]);
      await expectLater(check(), throwsA(isA<ModMonthFullBackupException>()
          .having((e) => e.code, 'code', 'migration_resume_tombstone_mismatch')));
      await db.customStatement('DELETE FROM tombstones');
      await db.customStatement(
        'INSERT INTO mod_month_pages '
        '(topic_id,month_key,diary_id,created_ms) VALUES(?,?,NULL,?)',
        ['expected-diary', '2026-11', 10],
      );
      await expectLater(check(), throwsA(isA<ModMonthFullBackupException>()
          .having((e) => e.code, 'code', 'migration_resume_graph_mismatch')));
    } finally {
      await db.close();
    }
  });

  test('native resume validates microsecond database timestamps against millisecond manifest', () async {
    final db = MoodiaryDatabase.forTesting(NativeDatabase.memory());
    try {
      await db.customSelect('SELECT 1').get();
      const manifestMs = 1794038400000;
      const databaseMicros = manifestMs * Duration.microsecondsPerMillisecond + 123;
      await db.customStatement(
        'INSERT INTO diaries '
        '(id,title,content,content_text,time,last_modified,show,type) '
        'VALUES(?,?,?,?,?,?,?,?)',
        ['native-001', 'safe', 'safe', 'safe', databaseMicros,
         databaseMicros, 1, 'tiptap'],
      );
      await db.customStatement(
        'INSERT INTO categories (id,name,last_modified) VALUES(?,?,?)',
        ['category-001', 'safe', databaseMicros],
      );
      await db.customStatement(
        'INSERT INTO places '
        '(id,name,latitude,longitude,last_modified) VALUES(?,?,?,?,?)',
        ['place-001', 'safe', 34.0, 110.0, databaseMicros],
      );
      final manifest = SyncManifest(
        version: SyncManifest.currentVersion,
        updatedAtMs: manifestMs,
        entries: {
          SyncKeys.diary('native-001'):
              const ManifestEntry(timeMs: manifestMs),
          SyncKeys.category('category-001'):
              const ManifestEntry(timeMs: manifestMs),
          SyncKeys.place('place-001'):
              const ManifestEntry(timeMs: manifestMs),
        },
      );
      final graph = await ModMonthGraphArchiveV2.exportGraph(db);
      Future<void> check() =>
          ModMonthFullBackupArchiveV1.validateResumeTarget(
            db: db, manifest: manifest, graph: graph, phase: 'native_imported',
          );
      // Source manifest carries milliseconds; the database correctly keeps
      // the original microseconds, including the 123-us fractional remainder.
      await check();
      await db.customStatement(
        'UPDATE places SET last_modified=? WHERE id=?',
        [databaseMicros + 1000, 'place-001'],
      );
      await expectLater(check(), throwsA(isA<ModMonthFullBackupException>()
          .having((e) => e.code, 'code', 'migration_resume_native_mismatch')));
      final current = await db.customSelect(
        'SELECT last_modified FROM diaries WHERE id=?',
        variables: [Variable.withString('native-001')],
      ).getSingle();
      expect(current.read<int>('last_modified'), databaseMicros,
          reason: 'validation must never modify the source timestamp');
    } finally {
      await db.close();
    }
  });

  test('resumed migration refuses altered native payload with unchanged ID and timestamp', () async {
    final db = MoodiaryDatabase.forTesting(NativeDatabase.memory());
    try {
      await db.customSelect('SELECT 1').get();
      const micros = 1794038400000123;
      const millis = 1794038400000;
      await db.customStatement(
        'INSERT INTO diaries '
        '(id,title,content,content_text,time,last_modified,show,type) '
        'VALUES(?,?,?,?,?,?,?,?)',
        ['diary-001', 'original diary', '{}', 'original', micros,
         micros, 1, 'tiptap'],
      );
      await db.customStatement(
        'INSERT INTO categories (id,name,last_modified) VALUES(?,?,?)',
        ['category-001', 'original category', micros],
      );
      await db.customStatement(
        'INSERT INTO places '
        '(id,name,latitude,longitude,last_modified) VALUES(?,?,?,?,?)',
        ['place-001', 'original place', 34.0, 110.0, micros],
      );
      final root = sandbox.path + '/verified-native';
      Future<void> archive(String relative, Map<String, dynamic> value) async {
        final file = File(root + '/' + relative);
        await file.parent.create(recursive: true);
        await file.writeAsString(jsonEncode(value), flush: true);
      }
      await archive('diary/diary-001.json',
          (await DiaryRepository(db).getDiaryByBusinessId('diary-001'))!.toJson());
      await archive('category/category-001.json',
          (await CategoryRepository(db).getCategoryById('category-001'))!.toJson());
      await archive('place/place-001.json',
          (await PlaceRepository(db).getPlaceById('place-001'))!.toJson());

      final manifest = SyncManifest(
        version: SyncManifest.currentVersion,
        updatedAtMs: millis,
        entries: {
          SyncKeys.diary('diary-001'): const ManifestEntry(timeMs: millis),
          SyncKeys.category('category-001'): const ManifestEntry(timeMs: millis),
          SyncKeys.place('place-001'): const ManifestEntry(timeMs: millis),
        },
      );
      Future<void> verify({bool partial = false}) =>
          ModMonthFullBackupArchiveV1.verifyNativePayloadReadback(
            db: db, manifest: manifest,
            verifiedDirectory: root, allowPartial: partial,
          );
      Future<void> rejected() => expectLater(
        verify(),
        throwsA(isA<ModMonthFullBackupException>().having(
          (e) => e.code, 'code', 'migration_native_payload_mismatch')),
      );

      await verify();
      await db.customStatement(
        'UPDATE diaries SET title=? WHERE id=?',
        ['unexpected edit', 'diary-001'],
      );
      await rejected();
      await db.customStatement(
        'UPDATE diaries SET title=? WHERE id=?',
        ['original diary', 'diary-001'],
      );
      await db.customStatement(
        'UPDATE categories SET name=? WHERE id=?',
        ['unexpected edit', 'category-001'],
      );
      await rejected();
      await db.customStatement(
        'UPDATE categories SET name=? WHERE id=?',
        ['original category', 'category-001'],
      );
      await db.customStatement(
        'UPDATE places SET latitude=? WHERE id=?',
        [35.0, 'place-001'],
      );
      await rejected();
      await db.customStatement(
        'UPDATE places SET latitude=? WHERE id=?',
        [34.0, 'place-001'],
      );
      await verify();

      // A crash before finishing native import may leave an absent row.
      // However, the fully-imported phase must never accept a missing row.
      await db.customStatement('DELETE FROM places WHERE id=?', ['place-001']);
      await verify(partial: true);
      await rejected();
      final row = await db.customSelect(
        'SELECT title FROM diaries WHERE id=?',
        variables: [Variable.withString('diary-001')],
      ).getSingle();
      expect(row.read<String>('title'), 'original diary',
          reason: 'safety validation is always read-only');
    } finally {
      await db.close();
    }
  });

  test('full backup refuses missing original media instead of claiming completeness', () {
    final now = DateTime.utc(2026, 11, 10);
    final diary = Diary(
      id: 'media-diary-001',
      title: 'native media closure',
      content: '',
      contentText: '',
      time: now,
      lastModified: now,
      show: true,
      imageName: const ['original.png'],
      audioName: const ['voice.m4a'],
      videoName: const ['clip.mp4'],
      fileName: const ['notes.pdf'],
      tags: const [],
      type: 'tiptap',
    );
    SyncManifest archive(List<String> media) => SyncManifest(
      version: SyncManifest.currentVersion,
      updatedAtMs: now.millisecondsSinceEpoch,
      entries: {
        SyncKeys.diary(diary.id): ManifestEntry(
          timeMs: now.millisecondsSinceEpoch,
          media: media,
        ),
      },
    );
    void verify(SyncManifest manifest) =>
        ModMonthFullBackupArchiveV1.verifyNativeMediaClosure(
          diaries: [diary], manifest: manifest,
        );
    final complete = [
      'image/original.png', 'audio/voice.m4a',
      'video/clip.mp4', 'file/notes.pdf',
    ];
    verify(archive(complete));
    // A generated video thumbnail is optional, but never the original video.
    for (final required in complete) {
      final incomplete = archive(complete.where((x) => x != required).toList());
      expect(
        () => verify(incomplete),
        throwsA(isA<ModMonthFullBackupException>().having(
          (e) => e.code, 'code', 'native_media_missing_from_archive',
        )),
        reason: 'must reject absent primary media: $required',
      );
    }
    expect(
      () => verify(SyncManifest(
        version: SyncManifest.currentVersion,
        updatedAtMs: 0,
        entries: const {},
      )),
      throwsA(isA<ModMonthFullBackupException>().having(
        (e) => e.code, 'code', 'native_diary_missing_from_archive',
      )),
    );
  });

  test('native media closure enforces per-diary refs and rejects unsafe paths', () {
    final now = DateTime.utc(2026, 11, 10);
    Diary diary(String id, String name) => Diary(
      id: id,
      title: id,
      content: '',
      contentText: '',
      time: now,
      lastModified: now,
      show: true,
      imageName: [name],
      audioName: const [],
      videoName: const [],
      fileName: const [],
      tags: const [],
      type: 'tiptap',
    );
    SyncManifest archive(Map<String, ManifestEntry> entries) =>
        SyncManifest(
          version: SyncManifest.currentVersion,
          updatedAtMs: now.millisecondsSinceEpoch,
          entries: entries,
        );
    final first = diary('first', 'shared.png');
    final second = diary('second', 'shared.png');
    final incomplete = archive({
      SyncKeys.diary(first.id): const ManifestEntry(
        timeMs: 1, media: ['image/shared.png'],
      ),
      SyncKeys.diary(second.id): const ManifestEntry(timeMs: 1),
    });
    expect(
      () => ModMonthFullBackupArchiveV1.verifyNativeMediaClosure(
        diaries: [first, second], manifest: incomplete,
      ),
      throwsA(isA<ModMonthFullBackupException>().having(
        (e) => e.code, 'code', 'native_media_missing_from_archive',
      )),
      reason: 'shared file must be referenced by each native diary',
    );
    final complete = archive({
      SyncKeys.diary(first.id): const ManifestEntry(
        timeMs: 1, media: ['image/shared.png'],
      ),
      SyncKeys.diary(second.id): const ManifestEntry(
        timeMs: 1, media: ['image/shared.png'],
      ),
    });
    ModMonthFullBackupArchiveV1.verifyNativeMediaClosure(
      diaries: [first, second], manifest: complete,
    );
    final unsafe = diary('first', '../outside.png');
    expect(
      () => ModMonthFullBackupArchiveV1.verifyNativeMediaClosure(
        diaries: [unsafe], manifest: complete,
      ),
      throwsA(isA<ModMonthFullBackupException>().having(
        (e) => e.code, 'code', 'invalid_native_media_name',
      )),
    );
  });

  test('original Moodiary plain ZIP imports to empty final app without W9 history', () async {
    await setUpSyncEnv();
    try {
      final originalDiary = Diary(
        id: 'original-note-001',
        title: '原版日记',
        content: '{"type":"doc","content":[{"type":"paragraph","content":[{"type":"text","text":"原版记录"}]}]}',
        contentText: '原版记录',
        categoryId: 'original-category',
        placeId: 'original-place',
        time: DateTime.utc(2024, 8, 5, 12, 30),
        lastModified: DateTime.utc(2025, 3, 4, 10, 20),
        show: true,
        imageName: const ['photo-original.png'],
        audioName: const [],
        videoName: const [],
        fileName: const ['original.pdf'],
        tags: const ['旧版', '工作'],
        type: 'tiptap',
      );
      final category = Category(
        id: 'original-category',
        categoryName: '工作记录',
        lastModified: DateTime.utc(2025, 1, 2),
      );
      final place = Place(
        id: 'original-place',
        name: '原始地点',
        latitude: 34.0,
        longitude: 110.0,
        lastModified: DateTime.utc(2025, 1, 2),
      );

      final mediaRoot = p.join(sandbox.path, 'original-media');
      for (final (directory, name, bytes) in [
        ('image', 'photo-original.png', utf8.encode('original photo bytes')),
        ('file', 'original.pdf', utf8.encode('original attachment bytes')),
      ]) {
        final file = File(p.join(mediaRoot, directory, name));
        await file.parent.create(recursive: true);
        await file.writeAsBytes(bytes);
      }
      final originalExport = p.join(sandbox.path, 'upstream-export');
      await LocalArchive.writeArchive(
        sink: _OriginalDirectorySink(originalExport),
        diaries: [originalDiary],
        categories: [category],
        places: [place],
        tombstones: const [],
        mediaBaseDir: mediaRoot,
      );
      final zipPath = p.join(sandbox.path, 'upstream-moodiary.zip');
      const python = r'''
import os, sys, zipfile
source, output = sys.argv[1:3]
with zipfile.ZipFile(output, "w", compression=zipfile.ZIP_STORED) as archive:
    for root, dirs, files in os.walk(source):
        for file in files:
            path = os.path.join(root, file)
            archive.write(path, os.path.relpath(path, source))
''';
      final zipResult = await Process.run(
        'python3', ['-c', python, originalExport, zipPath],
      );
      expect(zipResult.exitCode, 0, reason: zipResult.stderr.toString());
      final names = await ModMonthZipPreflightV2.inspectForBackupRouting(zipPath);
      expect(names, containsAll([
        'manifest.json',
        'diary/original-note-001.json',
        'category/original-category.json',
        'place/original-place.json',
        'media/image/photo-original.png',
        'media/file/original.pdf',
      ]));
      expect(
        ModMonthZipPreflightV2.hasCompleteFullHistoryMarkers(names),
        isFalse,
        reason: 'original app ZIP must use unchanged RestorePolicy import',
      );

      // Rust ZIP extraction is not available in Dart-only CI. Use the same
      // extracted ZIP directory to exercise the exact production importer.
      final destinationDiaries = FakeDiaryStore();
      final destinationCategories = FakeCategoryStore();
      final destinationPlaces = FakePlaceStore();
      final destinationMedia = FakeMediaFiles();
      final report = await LocalArchive.importDirectory(
        originalExport,
        policy: const RestorePolicy(),
        diaryStore: destinationDiaries,
        categoryStore: destinationCategories,
        placeStore: destinationPlaces,
        tombstoneStore: destinationDiaries.tombstones,
        mediaFiles: destinationMedia,
        cipherProvider: () async => SyncCipher.plaintext,
      );

      expect(report.failed, 0);
      expect(report.cancelled, false);
      expect(report.diaryCount, 1);
      final restored = destinationDiaries.diaries[originalDiary.id]!;
      expect(restored.title, originalDiary.title);
      expect(restored.content, originalDiary.content);
      expect(restored.contentText, originalDiary.contentText);
      expect(restored.time, originalDiary.time);
      expect(restored.categoryId, originalDiary.categoryId);
      expect(restored.placeId, originalDiary.placeId);
      expect(restored.tags, originalDiary.tags);
      expect(restored.show, originalDiary.show);
      expect(restored.imageName, originalDiary.imageName);
      expect(restored.fileName, originalDiary.fileName);
      expect(destinationCategories.categories[category.id]!.categoryName,
          category.categoryName);
      expect(destinationPlaces.places[place.id]!.name, place.name);
      expect(destinationMedia.files['image/photo-original.png'],
          utf8.encode('original photo bytes'));
      expect(destinationMedia.files['file/original.pdf'],
          utf8.encode('original attachment bytes'));
    } finally {
      await tearDownSyncEnv();
    }
  });

  test('official plain backup imports into real SQLite and preserves native media', () async {
    await setUpSyncEnv();
    final db = MoodiaryDatabase.forTesting(NativeDatabase.memory(
      setup: (raw) => raw.execute('PRAGMA foreign_keys = ON'),
    ));
    try {
      getIt.registerSingleton<DiaryRepository>(DiaryRepository(db));
      getIt.registerSingleton<CategoryRepository>(CategoryRepository(db));
      getIt.registerSingleton<PlaceRepository>(PlaceRepository(db));
      getIt.registerSingleton<TombstoneRepository>(TombstoneRepository(db));

      final created = DateTime.utc(2024, 8, 5, 12, 30);
      final modified = DateTime.utc(2025, 3, 4, 10, 20);
      const media = <(String, String)>[
        ('image', 'image-from-official.webp'),
        ('audio', 'audio-from-official.m4a'),
        ('video', 'video-from-official.mp4'),
        ('file', 'file-from-official.pdf'),
      ];
      final doc = jsonEncode({
        'type': 'doc',
        'attrs': {'v': 2},
        'content': [
          {
            'type': 'paragraph',
            'content': [
              {'type': 'text', 'text': '来自官方原版的中文日记'},
            ],
          },
          for (final (kind, name) in media)
            {
              'type': kind == 'file' ? 'attachment' : kind,
              'attrs': {
                'src': name,
                if (kind == 'file') 'name': '工作附件.pdf',
                if (kind == 'file') 'mime': 'application/pdf',
                if (kind == 'file') 'size': 16,
              },
            },
        ],
      });
      final original = Diary(
        id: 'official-sqlite-001',
        title: '官方原版真实数据库迁移',
        content: doc,
        contentText: '来自官方原版的中文日记',
        time: created,
        lastModified: modified,
        show: true,
        categoryId: 'official-category',
        placeId: 'official-place',
        imageName: const ['image-from-official.webp'],
        audioName: const ['audio-from-official.m4a'],
        videoName: const ['video-from-official.mp4'],
        fileName: const ['file-from-official.pdf'],
        tags: const ['工作', '光刻'],
        type: 'tiptap',
      );
      final textOnly = Diary(
        id: 'official-sqlite-002',
        title: '普通文字',
        content: jsonEncode({
          'type': 'doc',
          'attrs': {'v': 2},
          'content': [
            {'type': 'paragraph', 'content': [
              {'type': 'text', 'text': '第二篇原版记录'},
            ]},
          ],
        }),
        contentText: '第二篇原版记录',
        time: DateTime.utc(2023, 11, 10, 8),
        lastModified: DateTime.utc(2023, 11, 11, 8),
        show: true,
        imageName: const [],
        audioName: const [],
        videoName: const [],
        tags: const [],
        type: 'tiptap',
      );
      final category = Category(
        id: 'official-category',
        categoryName: '光刻设备',
        lastModified: modified,
      );
      final place = Place(
        id: 'official-place',
        name: '原版记录地点',
        latitude: 34.1,
        longitude: 110.2,
        lastModified: modified,
      );
      final mediaRoot = p.join(sandbox.path, 'official-source-media');
      final mediaBytes = <String, List<int>>{};
      for (final (kind, name) in media) {
        final bytes = utf8.encode('official-file/$kind/$name');
        mediaBytes['$kind/$name'] = bytes;
        final file = File(p.join(mediaRoot, kind, name));
        await file.parent.create(recursive: true);
        await file.writeAsBytes(bytes);
      }
      final archiveDir = p.join(sandbox.path, 'official-plain-export');
      await LocalArchive.writeArchive(
        sink: _OriginalDirectorySink(archiveDir),
        diaries: [original, textOnly],
        categories: [category],
        places: [place],
        tombstones: const [],
        mediaBaseDir: mediaRoot,
      );
      // This uses the same importer that the ordinary ZIP branch invokes
      // after extracting the official archive. The destination is real Drift
      // SQLite, not the fake stores used in the earlier routing test.
      final destMedia = p.join(sandbox.path, 'modded-app-media');
      final report = await LocalArchive.importDirectory(
        archiveDir,
        policy: const RestorePolicy(),
        diaryStore: RepoSyncDiaryStore(),
        categoryStore: RepoSyncCategoryStore(),
        placeStore: RepoSyncPlaceStore(),
        tombstoneStore: RepoSyncTombstoneStore(),
        mediaFiles: DiskSyncMediaFiles(baseDir: destMedia),
        cipherProvider: () async => SyncCipher.plaintext,
      );
      expect(report.failed, 0);
      expect(report.cancelled, isFalse);
      expect(report.diaryCount, 2);
      expect((await DiaryRepository(db).getAllDiaries()).length, 2);

      final saved = (await DiaryRepository(db)
          .getDiaryByBusinessId('official-sqlite-001'))!;
      expect(saved.title, original.title);
      expect(saved.content, original.content);
      expect(saved.contentText, contains('来自官方原版的中文日记'));
      expect(saved.time, created);
      expect(saved.categoryId, original.categoryId);
      expect(saved.placeId, original.placeId);
      expect(saved.tags, unorderedEquals(original.tags));
      expect(saved.imageName, original.imageName);
      expect(saved.audioName, original.audioName);
      expect(saved.videoName, original.videoName);
      expect(saved.fileName, original.fileName);
      final second = (await DiaryRepository(db)
          .getDiaryByBusinessId('official-sqlite-002'))!;
      expect(second.title, textOnly.title);
      expect(second.time, textOnly.time);
      expect(second.contentText, contains('第二篇原版记录'));
      expect((await CategoryRepository(db).getCategoryById(category.id))!
          .categoryName, category.categoryName);
      expect((await PlaceRepository(db).getPlaceById(place.id))!.name,
          place.name);
      for (final entry in mediaBytes.entries) {
        expect(
          await File(p.join(destMedia, entry.key)).readAsBytes(),
          entry.value,
          reason: 'media must be fully persisted: ${entry.key}',
        );
      }
      final invalidRelations = await db.customSelect('PRAGMA foreign_key_check').get();
      expect(invalidRelations, isEmpty);
      // The imported note is editable using the standard repository API.
      await DiaryRepository(db).insertADiary(
        saved.copyWith(title: '迁移后可以继续编辑'),
      );
      expect((await DiaryRepository(db)
          .getDiaryByBusinessId(original.id))!.title, '迁移后可以继续编辑');
    } finally {
      await db.close();
      await tearDownSyncEnv();
    }
  });

}
