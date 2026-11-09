"""W9.8.4.11: read-only Android recovery inventory UI."""
from pathlib import Path
import shutil
import sys

root = Path(sys.argv[1]).resolve()
here = Path(__file__).resolve().parent


def install(relative: str) -> None:
    source = here / "overlay" / relative
    target = root / relative
    if not source.is_file() or not target.parent.is_dir():
        raise SystemExit("W9.8.4.11 overlay source or target missing: " + relative)
    if target.exists():
        if target.read_bytes() != source.read_bytes():
            raise SystemExit("W9.8.4.11 source collision: " + relative)
    else:
        shutil.copyfile(source, target)
        print("ADDED: " + relative)


# The trusted Android root file is a deliberate, exact W9.8.4.9 successor.
root_relative = "packages/feature/moodiary_sync/lib/src/data/mod_month_android_restore_root_v2.dart"
root_source = here / "overlay" / root_relative
root_target = root / root_relative
if not root_source.is_file() or not root_target.is_file():
    raise SystemExit("W9.8.4.11 Android root baseline missing")
expected_root = root_source.read_text(encoding="utf-8")
current_root = root_target.read_text(encoding="utf-8")
if current_root != expected_root:
    root_method = """  /// Returns the already-existing, identity-verified Android private root.
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

"""
    root_facade = """  /// Opens an existing private root for read-only inspection, or returns null.
    /// It never creates the root or a workspace.
    static Future<ModMonthPrivateRestoreRootV2?> openExistingRootIfPresent() async {
    return ModMonthPrivateRestoreRootV2.openExistingIfPresentForSupport(
      applicationSupportDirectory:_supportRoot(),
    );
  }

"""
    if "openExistingIfPresentForSupport(" not in current_root:
        anchor = "  Future<void> _verifyDirectory() async {"
        if current_root.count(anchor) != 1:
            raise SystemExit("W9.8.4.11 root verification anchor mismatch")
        current_root = current_root.replace(anchor, root_method + anchor, 1)
    if "openExistingRootIfPresent()" not in current_root:
        anchor = "  static Future<ModMonthPrivateRestoreWorkspaceV2> createNew() async {"
        if current_root.count(anchor) != 1:
            raise SystemExit("W9.8.4.11 Android facade anchor mismatch")
        current_root = current_root.replace(anchor, root_facade + anchor, 1)
    if current_root != expected_root:
        raise SystemExit("W9.8.4.11 Android root baseline drift")
    root_target.write_text(current_root, encoding="utf-8")

for relative in (
    "mobile/lib/app/settings/storage/recovery_inventory_controller.dart",
    "mobile/lib/app/settings/storage/recovery_inventory_panel.dart",
    "mobile/test/app/settings/recovery_inventory_panel_test.dart",
    "packages/feature/moodiary_sync/test/sync/data/mod_month_android_restore_root_v2_test.dart",
):
    install(relative)

page = root / "mobile/lib/app/settings/storage/storage_page.dart"
page_text = page.read_text(encoding="utf-8")
if "import 'dart:io';" not in page_text:
    page_text = "import 'dart:io';\n\n" + page_text
import_anchor = "import 'storage_palette.dart';\n"
new_import = "import 'recovery_inventory_panel.dart';\n"
if new_import not in page_text:
    if page_text.count(import_anchor) != 1:
        raise SystemExit("W9.8.4.11 storage page import anchor mismatch")
    page_text = page_text.replace(import_anchor, import_anchor + new_import, 1)
page_anchor = "            _Categories(state: state),\n"
new_panel = "            if (Platform.isAndroid) const RecoveryInventoryPanel(),\n"
if new_panel not in page_text:
    if page_text.count(page_anchor) != 1:
        raise SystemExit("W9.8.4.11 storage page sliver anchor mismatch")
    page_text = page_text.replace(page_anchor, page_anchor + new_panel, 1)
page.write_text(page_text, encoding="utf-8")

pubspec = root / "mobile/pubspec.yaml"
version = pubspec.read_text(encoding="utf-8")
old = "version: 2.9.2+123"
new = "version: 2.9.2+124"
if version.count(old) == 1:
    pubspec.write_text(version.replace(old, new, 1), encoding="utf-8")
elif version.count(new) != 1:
    raise SystemExit("W9.8.4.11 mobile version anchor mismatch")

print("W9.8.4.11 read-only inventory UI applied; no delete, repair, or live restore")
