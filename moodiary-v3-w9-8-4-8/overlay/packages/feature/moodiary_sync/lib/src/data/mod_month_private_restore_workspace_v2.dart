// W9.8.4.8: isolate V2 ZIP cold restore inside a fresh caller-owned root.
//
// This developer-only adapter requires the *caller* to provide the directory
// obtained from Android application support storage. A path argument alone
// cannot prove filesystem permissions or Android application ownership.
// The API never opens, renames, deletes or activates live application storage.
import 'dart:convert';
import 'dart:io';

import 'package:moodiary_models/moodiary_models.dart';
import 'package:path/path.dart' as p;

import 'mod_month_recovery_slot_v2.dart';
import 'mod_month_verified_manifest_v1.dart' show ModBundleInvalid;
import 'mod_month_zip_bundle_v2.dart';
import 'mod_month_zip_generation_install_v2.dart';

final class ModMonthPrivateRestoreWorkspaceV2 {
  const ModMonthPrivateRestoreWorkspaceV2._(
      this.applicationSupportRoot, this.root);

  final String applicationSupportRoot;
  final String root;

  static const _prefix='.moodiary-v2-private-restore-';
  static const _identityName='workspace-identity.json';
  static const _slotName='generation-slot';
  static const _previewName='preview';
  static const _format='moodiary-v2-private-restore-workspace';

  static Never _fail(String code) => throw ModBundleInvalid(code);

  static Future<String> _canonicalSupportRoot(String path) async {
    final abs=p.normalize(p.absolute(path));
    if (await FileSystemEntity.type(abs,followLinks:false)!=
        FileSystemEntityType.directory) {
      _fail('private_root_not_regular_directory');
    }
    try {
      return p.normalize(await Directory(abs).resolveSymbolicLinks());
    } on FileSystemException {
      _fail('private_root_unverifiable');
    }
  }

  static Future<ModMonthPrivateRestoreWorkspaceV2> createNew(
      String applicationSupportDirectory) async {
    final parent=await _canonicalSupportRoot(applicationSupportDirectory);
    // Dart createTemp generates a fresh, collision-resistant child name.
    // Never reuse a pre-existing directory or a caller-selected name.
    final workspace=await Directory(parent).createTemp(_prefix);
    final instance=ModMonthPrivateRestoreWorkspaceV2._(
        parent,p.normalize(workspace.path));
    // A failure deliberately leaves this owned workspace for inspection.
    // It must not recursively delete a directory it can no longer prove.
    await File(p.join(instance.root,_identityName)).writeAsString(
      jsonEncode({
        'format':_format,'version':2,'isolatedOnly':true,
      }),
      flush:true,
    );
    await ModMonthRecoverySlotV2.createNew(
        p.join(instance.root,_slotName));
    return instance;
  }

  /// Only an explicitly marked, direct child of the supplied app-support
  /// directory can be reopened after an interrupted process.
  static Future<ModMonthPrivateRestoreWorkspaceV2> openExisting({
    required String applicationSupportDirectory,
    required String workspaceDirectory,
  }) async {
    final parent=await _canonicalSupportRoot(applicationSupportDirectory);
    final workspace=p.normalize(p.absolute(workspaceDirectory));
    final value=ModMonthPrivateRestoreWorkspaceV2._(parent,workspace);
    await value._verify();
    return value;
  }

  Future<ModMonthRecoverySlotV2> _verify() async {
    final parent=await _canonicalSupportRoot(applicationSupportRoot);
    if (parent!=applicationSupportRoot ||
        p.dirname(root)!=parent ||
        !p.basename(root).startsWith(_prefix)) {
      _fail('private_workspace_outside_root');
    }
    if (await FileSystemEntity.type(root,followLinks:false)!=
        FileSystemEntityType.directory) {
      _fail('private_workspace_not_directory');
    }
    try {
      if (p.normalize(await Directory(root).resolveSymbolicLinks())!=root) {
        _fail('private_workspace_alias');
      }
    } on FileSystemException {
      _fail('private_workspace_unverifiable');
    }

    final marker=File(p.join(root,_identityName));
    if (await FileSystemEntity.type(marker.path,followLinks:false)!=
        FileSystemEntityType.file) {
      _fail('private_workspace_identity_invalid');
    }
    if (await marker.length()<2 || await marker.length()>512) {
      _fail('private_workspace_identity_invalid');
    }
    final Object? identity;
    try {
      identity=jsonDecode(await marker.readAsString());
    } catch (_) {
      _fail('private_workspace_identity_invalid');
    }
    if (identity is! Map<String,dynamic> || identity.length!=3 ||
        identity['format']!=_format || identity['version']!=2 ||
        identity['isolatedOnly']!=true) {
      _fail('private_workspace_identity_invalid');
    }
    return ModMonthRecoverySlotV2.openExisting(p.join(root,_slotName));
  }

  /// Returns the verified read-only location of an isolated generation.
  Future<String?> currentDirectory() async {
    final slot=await _verify();
    return slot.currentDirectory();
  }

  /// Explicit restart recovery only, never a live-database activation.
  Future<String> recover() async {
    final slot=await _verify();
    return slot.recover();
  }

  /// Create a V2 cold restore from a regular ZIP file. The preview location
  /// and generation slot are derived exclusively from this owned workspace.
  Future<String> install({
    required String zipPath,
    required String generationId,
    required bool Function(Diary) isTopic,
    ModMonthZipTransportV2 transport=const ModMonthNativeZipTransportV2(),
    Future<void> Function(String)? checkpoint,
  }) async {
    final slot=await _verify();
    final source=p.normalize(p.absolute(zipPath));
    if (await FileSystemEntity.type(source,followLinks:false)!=
        FileSystemEntityType.file) {
      _fail('private_restore_archive_not_regular_file');
    }
    final String canonicalSource;
    try {
      canonicalSource=await File(source).resolveSymbolicLinks();
    } on FileSystemException {
      _fail('private_restore_archive_unverifiable');
    }
    if (p.isWithin(root,canonicalSource) || canonicalSource==root) {
      _fail('private_restore_archive_inside_workspace');
    }
    return ModMonthZipGenerationInstallV2.install(
      zipPath:canonicalSource,
      previewDirectory:p.join(root,_previewName),
      slot:slot,
      generationId:generationId,
      isTopic:isTopic,
      transport:transport,
      checkpoint:checkpoint,
    );
  }
}
