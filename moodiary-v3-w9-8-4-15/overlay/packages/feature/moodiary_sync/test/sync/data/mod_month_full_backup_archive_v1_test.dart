import 'package:flutter_test/flutter_test.dart';

import '../../../lib/src/data/mod_month_full_backup_archive_v1.dart';
import '../../../lib/src/data/mod_month_zip_preflight_v2.dart';
import '../../../lib/src/data/mod_month_verified_manifest_v1.dart';

void main() {
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
}
