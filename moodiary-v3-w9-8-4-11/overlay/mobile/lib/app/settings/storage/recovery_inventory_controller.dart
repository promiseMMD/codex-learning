import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:moodiary_sync/src/data/mod_month_android_restore_root_v2.dart';
import 'package:moodiary_sync/src/data/mod_month_restore_inventory_v2.dart';

/// A read-only snapshot of the already-existing Android private recovery root.
///
/// The Android facade returns null when the root does not exist. It never
/// creates a directory just because the user opened Storage settings.
final recoveryInventoryProvider =
    FutureProvider<ModRestoreInventorySnapshotV2>((ref) async {
  final root =
      await ModMonthAndroidPrivateRestoreV2.openExistingRootIfPresent();
  if (root == null) {
    return const ModRestoreInventorySnapshotV2([]);
  }
  return ModMonthRestoreInventoryV2.inspect(root);
});
