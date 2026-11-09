import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../../../lib/src/data/mod_month_full_backup_archive_v1.dart';
import '../../../lib/src/data/mod_month_zip_preflight_v2.dart';
import '../../../lib/src/data/mod_month_verified_manifest_v1.dart';

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

}
