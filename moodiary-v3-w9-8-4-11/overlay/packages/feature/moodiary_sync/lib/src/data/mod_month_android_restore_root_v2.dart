// W9.8.4.9 — Android application-private source binding for isolated V2 restore.
//
// Read-only/isolated developer API: never activates an existing diary database,
// imports over production media, or enables a restore screen. On Android the
// support directory comes ONLY from bootstrapPlatform() -> PlatformService ->
// path_provider, never from a ZIP, browser request, URI or arbitrary caller path.
//
// The directory-policy class is independently testable on Linux; only the
// Android-only facade may choose the support root from the live app platform.
import 'dart:convert';
import 'dart:io';

import 'package:moodiary_platform/moodiary_platform.dart';
import 'package:path/path.dart' as p;

import 'mod_month_private_restore_workspace_v2.dart';
import 'mod_month_verified_manifest_v1.dart' show ModBundleInvalid;

/// Container for strictly isolated V2 recovery workspaces.
///
/// Do not use this lower-level policy class as a trust source in production:
/// only [ModMonthAndroidPrivateRestoreV2] may acquire the Android support root.
final class ModMonthPrivateRestoreRootV2 {
  const ModMonthPrivateRestoreRootV2._(
    this.applicationSupportDirectory,
    this.root,
  );

  final String applicationSupportDirectory;
  final String root;

  static const directoryName='.moodiary-v2-private-recovery';
  static const _identityName='private-root-identity.json';
  static const _format='moodiary-v2-android-private-recovery-root';

  static Never _fail(String code) => throw ModBundleInvalid(code);

  static Future<String> _supportDirectory(String path) async {
    final absolute=p.normalize(p.absolute(path));
    if (await FileSystemEntity.type(absolute,followLinks:false)!=
        FileSystemEntityType.directory) {
      _fail('android_restore_support_not_directory');
    }
    try {
      return p.normalize(await Directory(absolute).resolveSymbolicLinks());
    } on FileSystemException {
      _fail('android_restore_support_unverifiable');
    }
  }

  static Future<ModMonthPrivateRestoreRootV2> createOrOpenForSupport({
    required String applicationSupportDirectory,
  }) async {
    final support=await _supportDirectory(applicationSupportDirectory);
    final rootPath=p.join(support,directoryName);
    final kind=await FileSystemEntity.type(rootPath,followLinks:false);
    if (kind==FileSystemEntityType.notFound) {
      // Never mkdir -p through a caller-selected path. The support directory
      // already exists and this one child has a fixed, reserved name.
      await Directory(rootPath).create();
      final holder=ModMonthPrivateRestoreRootV2._(support,rootPath);
      await holder._verifyDirectory();
      final marker=File(p.join(rootPath,_identityName));
      if (await FileSystemEntity.type(marker.path,followLinks:false)!=
          FileSystemEntityType.notFound) {
        _fail('android_restore_private_root_collision');
      }
      await marker.writeAsString(jsonEncode({
        'format':_format,
        'version':2,
        'isolatedOnly':true,
      }),flush:true);
      return holder;
    }
    final holder=ModMonthPrivateRestoreRootV2._(support,rootPath);
    await holder._verify();
    return holder;
  }

  /// Reopening never creates an unmarked directory. A crash before identity
  /// publication leaves the incomplete directory untouched for inspection.
  static Future<ModMonthPrivateRestoreRootV2> openExistingForSupport({
    required String applicationSupportDirectory,
  }) async {
    final support=await _supportDirectory(applicationSupportDirectory);
    final holder=ModMonthPrivateRestoreRootV2._(
        support,p.join(support,directoryName));
    await holder._verify();
    return holder;
  }

  /// Returns the already-existing, identity-verified Android private root.
  ///
  /// Unlike createOrOpenForSupport(), this method never creates the root.
  /// A missing root is a normal empty-state result for read-only inventory UI.
  static Future<ModMonthPrivateRestoreRootV2?> openExistingIfPresentForSupport({
    required String applicationSupportDirectory,
  }) async {
    final support=await _supportDirectory(applicationSupportDirectory);
    final rootPath=p.join(support,directoryName);
    final kind=await FileSystemEntity.type(rootPath,followLinks:false);
    if (kind==FileSystemEntityType.notFound) return null;
    final holder=ModMonthPrivateRestoreRootV2._(support,rootPath);
    await holder._verify();
    return holder;
  }

  Future<void> _verifyDirectory() async {
    final support=await _supportDirectory(applicationSupportDirectory);
    if (support!=applicationSupportDirectory ||
        root!=p.join(support,directoryName) ||
        p.dirname(root)!=support) {
      _fail('android_restore_private_root_outside_support');
    }
    if (await FileSystemEntity.type(root,followLinks:false)!=
        FileSystemEntityType.directory) {
      _fail('android_restore_private_root_not_directory');
    }
    try {
      if (p.normalize(await Directory(root).resolveSymbolicLinks())!=root) {
        _fail('android_restore_private_root_alias');
      }
    } on FileSystemException {
      _fail('android_restore_private_root_unverifiable');
    }
  }

  Future<void> _verify() async {
    await _verifyDirectory();
    final marker=File(p.join(root,_identityName));
    if (await FileSystemEntity.type(marker.path,followLinks:false)!=
        FileSystemEntityType.file) {
      _fail('android_restore_private_root_identity_invalid');
    }
    final length=await marker.length();
    if (length<2 || length>512) {
      _fail('android_restore_private_root_identity_invalid');
    }
    final Object? value;
    try {
      value=jsonDecode(await marker.readAsString());
    } catch (_) {
      _fail('android_restore_private_root_identity_invalid');
    }
    if (value is! Map<String,dynamic> || value.length!=3 ||
        value['format']!=_format || value['version']!=2 ||
        value['isolatedOnly']!=true) {
      _fail('android_restore_private_root_identity_invalid');
    }
  }

  Future<ModMonthPrivateRestoreWorkspaceV2> createNewWorkspace() async {
    await _verify();
    return ModMonthPrivateRestoreWorkspaceV2.createNew(root);
  }

  Future<ModMonthPrivateRestoreWorkspaceV2> openExistingWorkspace(
      String workspaceDirectory) async {
    await _verify();
    return ModMonthPrivateRestoreWorkspaceV2.openExisting(
      applicationSupportDirectory:root,
      workspaceDirectory:workspaceDirectory,
    );
  }
}

/// Only production-facing source of Android private restore workspaces.
/// These methods are *not* connected to app startup, settings, restore UI,
/// WebDAV, and cannot apply a generation to live diary/media directories.
final class ModMonthAndroidPrivateRestoreV2 {
  const ModMonthAndroidPrivateRestoreV2._();

  static Never _fail(String code) => throw ModBundleInvalid(code);

  static String _supportRoot() {
    if (!Platform.isAndroid) {
      _fail('android_restore_unsupported_platform');
    }
    // PlatformService is initialized by bootstrapPlatform() before any app UI.
    // Do not initialize it a second time or accept a path from user input.
    try {
      return PlatformService.get().applicationSupportPath;
    } on Error {
      // Access to the single late-final field is the only operation above.
      // A missing platform bootstrap must fail closed with a typed code.
      _fail('android_restore_platform_not_initialized');
    }
  }

  /// Opens an existing private root for read-only inspection, or returns null.
  /// It never creates the root or a workspace.
  static Future<ModMonthPrivateRestoreRootV2?> openExistingRootIfPresent() async {
    return ModMonthPrivateRestoreRootV2.openExistingIfPresentForSupport(
      applicationSupportDirectory:_supportRoot(),
    );
  }

  static Future<ModMonthPrivateRestoreWorkspaceV2> createNew() async {
    final root=await ModMonthPrivateRestoreRootV2.createOrOpenForSupport(
      applicationSupportDirectory:_supportRoot(),
    );
    return root.createNewWorkspace();
  }

  static Future<ModMonthPrivateRestoreWorkspaceV2> openExisting(
      {required String workspaceDirectory}) async {
    final root=await ModMonthPrivateRestoreRootV2.openExistingForSupport(
      applicationSupportDirectory:_supportRoot(),
    );
    return root.openExistingWorkspace(workspaceDirectory);
  }
}
