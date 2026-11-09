"""W9.8.4.13: parallel-safe Android package identity and migration contract."""
from pathlib import Path
import sys


def _extract_braced_block(source: str, marker: str) -> tuple[int, int, str]:
    if source.count(marker) != 1:
        raise SystemExit(f"Expected exactly one {marker!r} block")
    marker_pos = source.index(marker)
    start = source.rfind("\n", 0, marker_pos) + 1
    opening = source.find("{", marker_pos)
    if opening < 0:
        raise SystemExit(f"Missing opening brace for {marker}")
    depth = 0
    quote = None
    escaped = False
    for pos in range(opening, len(source)):
        char = source[pos]
        if quote:
            if escaped:
                escaped = False
            elif char == "\\":
                escaped = True
            elif char == quote:
                quote = None
            continue
        if char in ("'", '"'):
            quote = char
        elif char == "{":
            depth += 1
        elif char == "}":
            depth -= 1
            if depth == 0:
                return start, pos + 1, source[start:pos + 1]
    raise SystemExit(f"Unclosed Gradle flavor block: {marker}")


def ensure_v3safe_flavor(source: str) -> str:
    safe_marker = 'create("v3safe")'
    if safe_marker in source:
        _, _, safe_block = _extract_braced_block(source, safe_marker)
        if 'applicationIdSuffix = ".v3safe"' not in safe_block:
            raise SystemExit("Existing v3safe flavor has an unexpected applicationId")
        return source

    _, end, dev_block = _extract_braced_block(source, 'create("v3dev")')
    if dev_block.count('applicationIdSuffix = ".v3dev"') == 1:
        safe_block = dev_block.replace('create("v3dev")', safe_marker, 1)
        safe_block = safe_block.replace(
            'applicationIdSuffix = ".v3dev"',
            'applicationIdSuffix = ".v3safe"',
            1,
        )
    elif dev_block.count('applicationId = "cn.yooss.moodiary.v3dev"') == 1:
        safe_block = dev_block.replace('create("v3dev")', safe_marker, 1)
        safe_block = safe_block.replace(
            'applicationId = "cn.yooss.moodiary.v3dev"',
            'applicationId = "cn.yooss.moodiary.v3safe"',
            1,
        )
    else:
        raise SystemExit("Cannot safely clone v3dev application identity into v3safe")

    if 'applicationIdSuffix = ".v3dev"' in safe_block:
        raise SystemExit("v3safe flavor still carries the old package suffix")
    return source[:end] + "\n" + safe_block + source[end:]


def ensure_safe_version(source: str) -> str:
    old = "version: 2.9.2+124"
    new = "version: 2.9.3+125"
    if source.count(old) == 1:
        return source.replace(old, new, 1)
    if source.count(new) == 1:
        return source
    raise SystemExit("Unexpected mobile version baseline; refusing an unsafe version edit")


def main(root: Path) -> None:
    gradle = root / "mobile/android/app/build.gradle.kts"
    if not gradle.is_file():
        raise SystemExit("Android app Gradle file missing after pinned workspace preparation")
    gradle_source = gradle.read_text(encoding="utf-8")
    gradle_updated = ensure_v3safe_flavor(gradle_source)
    gradle.write_text(gradle_updated, encoding="utf-8")

    manifest = root / "mobile/android/app/src/main/AndroidManifest.xml"
    if not manifest.is_file() or 'android:label="@string/app_name"' not in manifest.read_text(encoding="utf-8"):
        raise SystemExit("Android manifest no longer uses the app_name resource")

    label = root / "mobile/android/app/src/v3safe/res/values/app_name.xml"
    label.parent.mkdir(parents=True, exist_ok=True)
    label_text = (
        '<?xml version="1.0" encoding="utf-8"?>\n'
        '<resources>\n'
        '    <string name="app_name">Moodiary 安全版</string>\n'
        '</resources>\n'
    )
    if label.exists() and label.read_text(encoding="utf-8") != label_text:
        raise SystemExit("W9.8.4.13 v3safe app label collision")
    label.write_text(label_text, encoding="utf-8")

    pubspec = root / "mobile/pubspec.yaml"
    if not pubspec.is_file():
        raise SystemExit("mobile/pubspec.yaml missing")
    version_updated = ensure_safe_version(pubspec.read_text(encoding="utf-8"))
    pubspec.write_text(version_updated, encoding="utf-8")

    export_page = root / "packages/feature/moodiary_export/lib/src/presentation/export_page.dart"
    backup_impl = root / "packages/feature/moodiary_sync/lib/src/data/impl/backup_archive_impl.dart"
    archive_impl = root / "packages/feature/moodiary_sync/lib/src/data/impl/local_archive.dart"
    for path in (export_page, backup_impl, archive_impl):
        if not path.is_file():
            raise SystemExit("Built-in local backup migration source missing: " + str(path))
    export_source = export_page.read_text(encoding="utf-8")
    backup_source = backup_impl.read_text(encoding="utf-8")
    archive_source = archive_impl.read_text(encoding="utf-8")
    for needle in (
        "getIt<IBackupArchive>().export()",
        "getIt<IBackupArchive>().import(file.path)",
        "allowedExtensions: ['zip']",
    ):
        if needle not in export_source:
            raise SystemExit("Existing backup UI contract missing: " + needle)
    for needle in (
        "LocalArchive.export()",
        "LocalArchive.import(",
        "policy: const RestorePolicy()",
    ):
        if needle not in backup_source:
            raise SystemExit("Existing backup archive contract missing: " + needle)
    for needle in (
        "diaries: diaries",
        "categories: categories",
        "places: places",
        "mediaBaseDir: PlatformService.get().applicationSupportPath",
    ):
        if needle not in archive_source:
            raise SystemExit("Backup payload does not prove diary/media coverage: " + needle)

    # Do not overstate the upstream ZIP: it omits the custom W9 graph.
    graph = root / "packages/feature_base/moodiary_data/lib/src/mod_month_graph_archive_v2.dart"
    stage = root / "packages/feature/moodiary_sync/lib/src/data/mod_month_stream_stage_v2.dart"
    bundle = root / "packages/feature/moodiary_sync/lib/src/data/mod_month_zip_bundle_v2.dart"
    isolated = root / "packages/feature/moodiary_sync/lib/src/data/mod_month_isolated_restore_v2.dart"
    for path in (graph, stage, bundle, isolated):
        if not path.is_file():
            raise SystemExit("W9 custom archive implementation missing: " + str(path))
    for source, needles, label in (
        (graph, (
            "This is NOT a user backup, ZIP, WebDAV, native Diary or media archive.",
            "restoreIntoIsolatedEmptyDatabaseForTest",
        ), "W9 graph archive test-only contract"),
        (stage, (
            "NO production restore, ZIP export, WebDAV integration or ordinary Diary projection.",
        ), "W9 streaming stage production-integration boundary"),
        (bundle, (
            "No live database writes, no WebDAV transport and no production backup UI.",
            "It is NOT a native Diary restore, nor is it wired to the backup UI.",
        ), "W9 ZIP bundle production-integration boundary"),
        (isolated, (
            "NEVER opens the app's live SQLite or media path.",
        ), "W9 isolated restore safety boundary"),
    ):
        text = source.read_text(encoding="utf-8")
        for needle in needles:
            if needle not in text:
                raise SystemExit("W9 migration readiness contract changed: " + label + ": " + needle)

    print("W9.8.4.13 applied: cn.yooss.moodiary.v3safe is a parallel-install package")
    print("Standard native Diary ZIP export/import contract verified; old app remains untouched")
    print("IMPORTANT: W9 custom monthly/day graph migration is NOT production-wired; do not claim full migration readiness")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit("Usage: apply_w9_8_4_13.py <prepared-upstream-root>")
    main(Path(sys.argv[1]).resolve())
