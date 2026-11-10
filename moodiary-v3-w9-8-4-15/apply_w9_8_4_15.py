"""W9.8.4.15: production full-history backup and safe resumable migration."""
from pathlib import Path
import shutil
import sys

root = Path(sys.argv[1]).resolve()
here = Path(__file__).resolve().parent

# New production service and its tests are additive overlays.
for source in (here / "overlay").rglob("*"):
    if source.is_file():
        target = root / source.relative_to(here / "overlay")
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, target)

def patch(relative: str, old: str, new: str) -> None:
    path = root / relative
    source = path.read_text(encoding="utf-8")
    if new in source:
        return
    count = source.count(old)
    if count != 1:
        raise SystemExit(f"W9.8.4.15 patch anchor mismatch: {relative}: {count}")
    path.write_text(source.replace(old, new, 1), encoding="utf-8")

archive_apply = "packages/feature/moodiary_sync/lib/src/data/archive_apply.dart"
patch(
    archive_apply,
    """  bool get localTombstonesBlockWrite;
}""",
    """  bool get localTombstonesBlockWrite;

  /// Preserve source timestamps for a full-fidelity local migration.
  bool get preservesTimestamps => false;
}""",
)
patch(
    archive_apply,
    """class RestorePolicy extends ArchiveApplyPolicy {
  const RestorePolicy();

  @override
  bool get appliesTombstones => false;

  @override
  bool get localTombstonesBlockWrite => false;
}""",
    """class RestorePolicy extends ArchiveApplyPolicy {
  const RestorePolicy();

  @override
  bool get appliesTombstones => false;

  @override
  bool get localTombstonesBlockWrite => false;
}

/// Used only by the new-app full migration path. Native tombstones are
/// restored explicitly after object import; source timestamps are retained.
class FullMigrationRestorePolicy extends ArchiveApplyPolicy {
  const FullMigrationRestorePolicy();

  @override
  bool get appliesTombstones => false;

  @override
  bool get localTombstonesBlockWrite => false;

  @override
  bool get preservesTimestamps => true;
}""",
)
patch(
    archive_apply,
    """            restoring && oldDiary == null
                ? diary.copyWith(lastModified: DateTime.timestamp())
                : diary,""",
    """            restoring && oldDiary == null && !policy.preservesTimestamps
                ? diary.copyWith(lastModified: DateTime.timestamp())
                : diary,""",
)
patch(
    archive_apply,
    """            restoring && freshLocal == null
                ? category.copyWith(lastModified: DateTime.timestamp())
                : category,""",
    """            restoring && freshLocal == null && !policy.preservesTimestamps
                ? category.copyWith(lastModified: DateTime.timestamp())
                : category,""",
)
patch(
    archive_apply,
    """            restoring && freshLocal == null
                ? place.copyWith(lastModified: DateTime.timestamp())
                : place,""",
    """            restoring && freshLocal == null && !policy.preservesTimestamps
                ? place.copyWith(lastModified: DateTime.timestamp())
                : place,""",
)

local_archive = "packages/feature/moodiary_sync/lib/src/data/impl/local_archive.dart"
archive_path = root / local_archive
archive_text = archive_path.read_text(encoding="utf-8")
method_marker = "  static Future<SyncReport> importDirectory("
begin = archive_text.find(method_marker)
if begin < 0:
    raise SystemExit("W9.8.4.15: importDirectory declaration missing")
end = archive_text.find("\n  }\n}", begin)
if end < 0:
    raise SystemExit("W9.8.4.15: importDirectory method end missing")
section = archive_text[begin:end]
signature_end = section.find("  }) async {")
if signature_end < 0:
    raise SystemExit("W9.8.4.15: importDirectory signature has changed")
if "afterApply" not in section[:signature_end]:
    section = (
        section[:signature_end]
        + "    Future<void> Function(SyncReport)? afterApply,\n"
        + section[signature_end:]
    )
if "await afterApply?.call(report)" not in section:
    import re
    rx = re.compile(
        r"return runSyncExclusive\(\s*\(\)\s*=>\s*"
        r"(ArchiveApplier\(.*?\)\.apply\(SyncManifest\.fromJson\(decoded\)\))"
        r",\s*\);",
        re.S,
    )
    match = rx.search(section)
    if match is None:
        print("importDirectory source excerpt:", section[-1300:])
        raise SystemExit("W9.8.4.15: cannot safely wrap importDirectory apply call")
    replacement = (
        "return runSyncExclusive(() async {\n"
        "      final report = await " + match.group(1) + ";\n"
        "      await afterApply?.call(report);\n"
        "      return report;\n"
        "    });"
    )
    section = section[:match.start()] + replacement + section[match.end():]
archive_text = archive_text[:begin] + section + archive_text[end:]
archive_path.write_text(archive_text, encoding="utf-8")

backup_impl = "packages/feature/moodiary_sync/lib/src/data/impl/backup_archive_impl.dart"
patch(
    backup_impl,
    """import 'package:injectable/injectable.dart';
import 'package:moodiary_data/moodiary_data.dart';

import '../archive_apply.dart';
import 'local_archive.dart';""",
    """import 'package:injectable/injectable.dart';
import 'package:moodiary_data/moodiary_data.dart';
import 'package:moodiary_di/moodiary_di.dart';

import '../archive_apply.dart';
import '../mod_month_full_backup_archive_v1.dart';
import '../mod_month_verified_manifest_v2.dart';
import '../mod_month_zip_preflight_v2.dart';
import 'local_archive.dart';""",
)
patch(
    backup_impl,
    """  Future<String> export() => LocalArchive.export();

  @override
  Future<BackupImportResult> import(String zipPath) async {
    final report = await LocalArchive.import(
      zipPath,
      policy: const RestorePolicy(),
    );
    return BackupImportResult(
      diaryCount: report.diaryCount,
      categoryCount: report.categoryCount,
      mediaCount: report.pulled.mediaFiles,
      failed: report.failed,
      cancelled: report.cancelled,
      skipped: report.skipped,
    );
  }""",
    """  Future<String> export() => ModMonthFullBackupArchiveV1.export(
    db: getIt<MoodiaryDatabase>(),
  );

  @override
  Future<BackupImportResult> import(String zipPath) async {
    // Existing ordinary backup ZIPs must remain importable. A ZIP with an
    // incomplete V2 history marker is rejected instead of being downgraded.
    // The legacy branch preserves the upstream RestorePolicy exactly.
    final names = await ModMonthZipPreflightV2.inspectForBackupRouting(zipPath);
    final fullHistory =
        ModMonthZipPreflightV2.hasCompleteFullHistoryMarkers(names);
    final report = fullHistory
        ? await ModMonthFullBackupArchiveV1.importZip(
            zipPath: zipPath,
            db: getIt<MoodiaryDatabase>(),
          )
        : await LocalArchive.import(
            zipPath,
            // Preserve original metadata only for first import into an empty
            // modded app. Never change ordinary nonempty backup restore.
            policy: await ModMonthFullBackupArchiveV1.originalImportPolicyFor(
              getIt<MoodiaryDatabase>(),
            ),
          );
    return BackupImportResult(
      diaryCount: report.pulled.diaries,
      categoryCount: report.pulled.categories,
      mediaCount: report.pulled.mediaFiles,
      failed: report.failed,
      cancelled: report.cancelled,
      skipped: report.skipped,
    );
  }""",
)

pubspec = root / "mobile/pubspec.yaml"
source = pubspec.read_text(encoding="utf-8")
if "version: 2.9.2+126" not in source:
    if source.count("version: 2.9.2+125") != 1:
        raise SystemExit("W9.8.4.15 version anchor mismatch")
    pubspec.write_text(
        source.replace("version: 2.9.2+125", "version: 2.9.2+126", 1),
        encoding="utf-8",
    )

print("W9.8.4.15 applied: complete native + W9 history + media backup/import path")
print("Migration requires a full V2 graph; legacy snapshot-only ZIPs fail closed")
print("Native source timestamps and tombstones are preserved; old app is untouched")
