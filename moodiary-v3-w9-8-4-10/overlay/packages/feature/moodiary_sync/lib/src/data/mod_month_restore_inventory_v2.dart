// W9.8.4.10 — non-mutating inventory of Android-private V2 restore copies.
//
// A directory holding a recovery journal, unknown file, symlink or invalid
// identity is evidence to preserve, NOT a cache entry that can be deleted.
// This class provides no delete, purge, prune, activation or auto-repair API.
// A caller must open the identity-checked app-private root first.
import 'dart:io';

import 'package:path/path.dart' as p;

import 'mod_month_android_restore_root_v2.dart';
import 'mod_month_verified_manifest_v1.dart' show ModBundleInvalid;

enum ModRestoreInventoryStateV2 {
  empty,
  ready,
  recoveryRequired,
  needsReview,
  unrecognized,
}

final class ModRestoreInventoryEntryV2 {
  const ModRestoreInventoryEntryV2({
    required this.path,
    required this.state,
    required this.bytes,
    required this.files,
    required this.activeDirectory,
  });

  final String path;
  final ModRestoreInventoryStateV2 state;

  /// Null when safety checks or bounded scanning cannot establish a size.
  final int? bytes;
  final int? files;
  final String? activeDirectory;
}

final class ModRestoreInventorySnapshotV2 {
  const ModRestoreInventorySnapshotV2(this.entries);

  final List<ModRestoreInventoryEntryV2> entries;

  /// Any isolated copy, unknown directory or unverified item blocks
  /// an automatic "clear everything" claim until explicitly reviewed.
  /// This is a policy bit, not a delete action.
  bool get requiresExplicitRetentionDecision => entries.isNotEmpty;

  int get knownBytes => entries.fold(0, (total, entry) =>
      total + (entry.bytes ?? 0));

  bool get hasUnverifiedItems => entries.any((entry) =>
      entry.state==ModRestoreInventoryStateV2.needsReview ||
      entry.state==ModRestoreInventoryStateV2.unrecognized ||
      entry.state==ModRestoreInventoryStateV2.recoveryRequired);
}

final class ModMonthRestoreInventoryV2 {
  const ModMonthRestoreInventoryV2._();

  static const _workspacePrefix='.moodiary-v2-private-restore-';
  static const _rootIdentity='private-root-identity.json';
  static const _workspaceIdentity='workspace-identity.json';
  static const _slotName='generation-slot';

  // Avoid unbounded traversal on large or corrupt directory trees.
  // Exceeding limits means "needs review", never "safe to delete".
  static const maxEntries=50000;
  static const maxMeasuredBytes=256*1024*1024*1024;

  static Future<({int bytes,int files})?> _measure(String root) async {
    var total=0;
    var files=0;
    var entries=0;
    try {
      await for (final entry in Directory(root).list(
          recursive:true, followLinks:false)) {
        entries++;
        if (entries>maxEntries) return null;
        final kind=await FileSystemEntity.type(
            entry.path, followLinks:false);
        if (kind==FileSystemEntityType.directory) continue;
        if (kind!=FileSystemEntityType.file) return null;
        final size=await File(entry.path).length();
        if (size<0 || size>maxMeasuredBytes-total) return null;
        total+=size;
        files++;
      }
    } on FileSystemException {
      return null;
    }
    return (bytes:total,files:files);
  }

  /// A workspace is known only when its exact parent and identity are checked
  /// by W9.8.4.8, which in turn requires W9.8.4.9's verified root.
  /// This method NEVER calls recover(): journal reconciliation can write.
  static Future<ModRestoreInventorySnapshotV2> inspect(
      ModMonthPrivateRestoreRootV2 root) async {
    final verified=await ModMonthPrivateRestoreRootV2.openExistingForSupport(
        applicationSupportDirectory:root.applicationSupportDirectory);
    if (verified.root!=root.root) {
      throw const ModBundleInvalid('restore_inventory_root_mismatch');
    }
    final items=<ModRestoreInventoryEntryV2>[];
    await for (final entry in Directory(verified.root).list(
        followLinks:false)) {
      final name=p.basename(entry.path);
      if (name==_rootIdentity) continue;
      final kind=await FileSystemEntity.type(
          entry.path,followLinks:false);
      // A foreign file is never treated as owned or scanned recursively.
      if (!name.startsWith(_workspacePrefix) ||
          kind!=FileSystemEntityType.directory) {
        items.add(ModRestoreInventoryEntryV2(
          path:entry.path,
          state:ModRestoreInventoryStateV2.unrecognized,
          bytes:null,files:null,activeDirectory:null,
        ));
        continue;
      }

      try {
        final workspace=await verified.openExistingWorkspace(entry.path);
        final measure=await _measure(workspace.root);
        if (measure==null) {
          items.add(ModRestoreInventoryEntryV2(
            path:entry.path,
            state:ModRestoreInventoryStateV2.needsReview,
            bytes:null,files:null,activeDirectory:null,
          ));
          continue;
        }

        var needsReview=false;
        await for (final item in Directory(workspace.root).list(
            followLinks:false)) {
          final part=p.basename(item.path);
          final kind=await FileSystemEntity.type(
              item.path, followLinks:false);
          if (part==_workspaceIdentity &&
              kind==FileSystemEntityType.file) continue;
          if (part==_slotName &&
              kind==FileSystemEntityType.directory) continue;
          // A leftover preview, quarantine, or unknown file may contain data.
          needsReview=true;
        }

        final journal=p.join(workspace.root,_slotName,
            'recovery-journal.json');
        final journalKind=await FileSystemEntity.type(
            journal,followLinks:false);
        String? active;
        var state=ModRestoreInventoryStateV2.empty;
        if (journalKind!=FileSystemEntityType.notFound) {
          state=ModRestoreInventoryStateV2.recoveryRequired;
        } else {
          active=await workspace.currentDirectory();
          if (active!=null) {
            state=ModRestoreInventoryStateV2.ready;
          }
        }
        if (needsReview && state!=ModRestoreInventoryStateV2.recoveryRequired) {
          state=ModRestoreInventoryStateV2.needsReview;
        }
        items.add(ModRestoreInventoryEntryV2(
          path:entry.path,state:state,
          bytes:measure.bytes,files:measure.files,
          activeDirectory:active,
        ));
      } on FileSystemException {
        items.add(ModRestoreInventoryEntryV2(
          path:entry.path,
          state:ModRestoreInventoryStateV2.needsReview,
          bytes:null,files:null,activeDirectory:null,
        ));
      } on ModBundleInvalid {
        items.add(ModRestoreInventoryEntryV2(
          path:entry.path,
          state:ModRestoreInventoryStateV2.needsReview,
          bytes:null,files:null,activeDirectory:null,
        ));
      }
    }
    items.sort((a,b)=>a.path.compareTo(b.path));
    return ModRestoreInventorySnapshotV2(List.unmodifiable(items));
  }
}
