import 'package:flutter_test/flutter_test.dart';

// This file deliberately imports the *production* full-backup service so CI
// compiles its complete API graph. Previously the new service was never
// referenced by any focused test and could pass CI without compilation.
import '../../../lib/src/data/mod_month_full_backup_archive_v1.dart';

void main() {
  test('full-backup service and error type are compiled into tests', () {
    const error = ModMonthFullBackupException('expected_failure');
    expect(error.code, 'expected_failure');
    expect(error.toString(), contains('expected_failure'));
    expect(ModMonthFullBackupArchiveV1, isNotNull);
  });
}
