// W9.7.7 — read-only, bounded recovery quarantine inspection.
//
// This does NOT delete, rename, resume, publish, adopt or open any live Diary.
// In particular a "ready" checkpoint is NOT proof of valid SQLite or media.
// Only an explicit future app-level recovery transaction may act on a report.
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'mod_month_verified_manifest_v1.dart';

enum ModMonthOrphanTypeV1 { archiveZip, isolatedRestore }

enum ModMonthOrphanConditionV1 {
  /// ZIP transport's private directory; no durable restore journal exists.
  unknownArchiveStage,

  /// Valid W9.7.5 journal but no trusted publication has happened.
  incompleteRestore,

  /// Journal says ready; payload must still be re-verified, never activated.
  readyButUnverified,

  /// A known staging name with a missing, forged, oversized or bad journal.
  invalidRestoreJournal,

  /// A symlink, file, special entry or anything other than a directory.
  unsafeStagingEntry,
}

final class ModMonthOrphanFindingV1 {
  const ModMonthOrphanFindingV1({
    required this.name,
    required this.kind,
    required this.condition,
    required this.phase,
    required this.modifiedUtc,
  });

  /// Basename only, not a URL or a filesystem path that can escape the root.
  final String name;
  final ModMonthOrphanTypeV1 kind;
  final ModMonthOrphanConditionV1 condition;

  /// Non-sensitive checkpoint name if the journal was well formed.
  final String? phase;

  /// Filesystem metadata only. No attached Diary content is inspected.
  final DateTime? modifiedUtc;

  /// This status never authorizes deletion or in-place recovery.
  bool get requiresHumanReview => true;
}

final class ModMonthOrphanInspectorV1 {
  const ModMonthOrphanInspectorV1._();

  static const int maxScannedChildren = 4096;
  static const int maxKnownStagingEntries = 256;
  static const int maxStateBytes = 4096;

  static const _zipPrefix = '.moodiary-w974-';
  static const _restorePrefix = '.moodiary-w975-';
  static const _phases = <String>{
    'created',
    'graph_restored',
    'native_restored',
    'media_restored',
    'readback_complete',
    'ready',
  };

  static Never _fail(String code) => throw ModBundleInvalid(code);

  static bool _stagingName(String name, String prefix) =>
      name.startsWith(prefix) &&
      name.length > prefix.length &&
      RegExp(r'^[A-Za-z0-9_-]+$')
          .hasMatch(name.substring(prefix.length));

  static Future<(ModMonthOrphanConditionV1, String?)> _phase(
      Directory directory) async {
    final journal=File(p.join(directory.path,'restore-state.json'));
    if (await FileSystemEntity.type(journal.path,followLinks:false)!=
        FileSystemEntityType.file) {
      return (ModMonthOrphanConditionV1.invalidRestoreJournal,null);
    }
    final size=await journal.length();
    if (size<2 || size>maxStateBytes) {
      return (ModMonthOrphanConditionV1.invalidRestoreJournal,null);
    }
    try {
      final bytes=await journal.readAsBytes();
      // Reject truncated or concurrent mutation. The scanner never retries a
      // malformed state as a trusted "ready" checkpoint.
      if (bytes.length!=size) {
        return (ModMonthOrphanConditionV1.invalidRestoreJournal,null);
      }
      final decoded=jsonDecode(utf8.decode(bytes,allowMalformed:false));
      if (decoded is! Map<String,dynamic> ||
          decoded.length!=4 ||
          decoded['format']!='moodiary-isolated-restore' ||
          decoded['version']!=1 ||
          decoded['liveDataModified']!=false ||
          decoded['phase'] is! String ||
          !_phases.contains(decoded['phase'])) {
        return (ModMonthOrphanConditionV1.invalidRestoreJournal,null);
      }
      final phase=decoded['phase'] as String;
      return (
        phase=='ready'
          ? ModMonthOrphanConditionV1.readyButUnverified
          : ModMonthOrphanConditionV1.incompleteRestore,
        phase
      );
    } catch (_) {
      return (ModMonthOrphanConditionV1.invalidRestoreJournal,null);
    }
  }

  /// A bounded, non-recursive examination of the parent of W9.7.4/7.5
  /// temporary directories. Never follows symlinks and never reads payloads.
  ///
  /// Invalid or overlarge directory listings fail closed. The caller must
  /// supply a trusted PRIVATE parent; do not use the user's shared storage.
  static Future<List<ModMonthOrphanFindingV1>> scanPrivateParent(
      String privateParent) async {
    final root=p.normalize(p.absolute(privateParent));
    if (await FileSystemEntity.type(root,followLinks:false)!=
        FileSystemEntityType.directory) {
      _fail('orphan_parent_not_private_directory');
    }
    final result=<ModMonthOrphanFindingV1>[];
    var scanned=0;
    await for (final entry in Directory(root)
        .list(recursive:false,followLinks:false)) {
      scanned++;
      if (scanned>maxScannedChildren) _fail('orphan_scan_limit');
      final name=p.basename(entry.path);
      final zip=_stagingName(name,_zipPrefix);
      final isolated=_stagingName(name,_restorePrefix);
      if (!zip && !isolated) continue;
      if (result.length>=maxKnownStagingEntries) {
        _fail('orphan_staging_limit');
      }
      final kind=zip
          ? ModMonthOrphanTypeV1.archiveZip
          : ModMonthOrphanTypeV1.isolatedRestore;
      final type=await FileSystemEntity.type(entry.path,followLinks:false);
      DateTime? changed;
      if (type==FileSystemEntityType.directory) {
        try {
          changed=(await Directory(entry.path).stat()).modified.toUtc();
        } catch (_) {
          // Permission or transient I/O errors are unknown, never "ready".
        }
      }
      final (condition,phase)=type!=FileSystemEntityType.directory
          ? (ModMonthOrphanConditionV1.unsafeStagingEntry,null)
          : zip
              ? (ModMonthOrphanConditionV1.unknownArchiveStage,null)
              : await _phase(Directory(entry.path));
      result.add(ModMonthOrphanFindingV1(
        name:name,
        kind:kind,
        condition:condition,
        phase:phase,
        modifiedUtc:changed,
      ));
    }
    result.sort((a,b)=>a.name.compareTo(b.name));
    return result;
  }
}
