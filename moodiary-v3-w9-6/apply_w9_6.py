"""W9.6 fail-closed preflight for legacy cloud/ZIP with structured W9 rows."""
from pathlib import Path
import sys, shutil

root = Path(sys.argv[1]).resolve()
here = Path(__file__).resolve().parent
for source in (here / 'overlay').rglob('*'):
    if source.is_file():
        target = root / source.relative_to(here / 'overlay')
        if target.exists():
            raise SystemExit(f'W9.6 would overwrite a previous source: {target}')
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, target)

def patch(relative, old, new):
    path = root / relative
    value = path.read_text(encoding='utf-8')
    if value.count(old) != 1:
        raise SystemExit(f'W9.6 anchor drift in {relative}: {old[:70]!r}')
    path.write_text(value.replace(old, new, 1), encoding='utf-8')

patch('packages/feature_base/moodiary_data/lib/moodiary_data.dart',
      "export 'src/backup_archive.dart';",
      "export 'src/backup_archive.dart';\nexport 'src/mod_month_archive_gate.dart';")

engine = 'packages/feature/moodiary_sync/lib/src/data/incremental_engine.dart'
patch(engine, '  Future<SyncReport> pull({bool markSynced = true}) async {',
      """  Future<void> _checkStructuredArchiveCoverage() async {
    if (_diaryStore is RepoSyncDiaryStore) {
      await ModMonthArchiveGate.requireLegacyOnly(getIt<MoodiaryDatabase>());
    }
  }

  Future<SyncReport> pull({bool markSynced = true}) async {
    await _checkStructuredArchiveCoverage();""")
patch(engine, '  Future<SyncReport> push() async {\n    final report =',
      '  Future<SyncReport> push() async {\n    await _checkStructuredArchiveCoverage();\n    final report =')
patch(engine, '  Future<SyncReport> sync() async {\n    final report =',
      '  Future<SyncReport> sync() async {\n    await _checkStructuredArchiveCoverage();\n    final report =')

patch('packages/feature/moodiary_sync/lib/src/data/archive_apply.dart',
      '  Future<SyncReport> apply(SyncManifest manifest) async {\n    final restoring',
      """  Future<SyncReport> apply(SyncManifest manifest) async {
    if (_diaryStore is RepoSyncDiaryStore) {
      await ModMonthArchiveGate.requireLegacyOnly(getIt<MoodiaryDatabase>());
    }
    final restoring""")

archive = 'packages/feature/moodiary_sync/lib/src/data/impl/local_archive.dart'
patch(archive, "import 'package:moodiary_i18n/moodiary_i18n.dart';",
      "import 'package:moodiary_i18n/moodiary_i18n.dart';\n"
      "import 'package:moodiary_data/moodiary_data.dart';\n"
      "import 'package:moodiary_di/moodiary_di.dart';")
patch(archive, 'class LocalArchive {\n  LocalArchive._();',
      """class LocalArchive {
  LocalArchive._();

  static Future<void> _assertCompleteArchiveSupported() =>
      ModMonthArchiveGate.requireLegacyOnly(getIt<MoodiaryDatabase>());""")
for _ in range(2):
    patch(archive, '    return IncrementalSyncEngine.runExclusive(() async {\n      final diaries',
      '    return IncrementalSyncEngine.runExclusive(() async {\n      await _assertCompleteArchiveSupported();\n      final diaries')
patch(archive,
      """  static Future<SyncManifest> buildLocalManifest() async => buildManifest(
    diaries: await RepoSyncDiaryStore().getAllDiaries(),
    categories: await RepoSyncCategoryStore().getAllCategoriesForSync(),
    places: await RepoSyncPlaceStore().getAllPlacesForSync(),
    tombstones: await RepoSyncTombstoneStore().getAll(),
    mediaBaseDir: PlatformService.get().applicationSupportPath,
  );""",
      """  static Future<SyncManifest> buildLocalManifest() async {
    await _assertCompleteArchiveSupported();
    return buildManifest(
      diaries: await RepoSyncDiaryStore().getAllDiaries(),
      categories: await RepoSyncCategoryStore().getAllCategoriesForSync(),
      places: await RepoSyncPlaceStore().getAllPlacesForSync(),
      tombstones: await RepoSyncTombstoneStore().getAll(),
      mediaBaseDir: PlatformService.get().applicationSupportPath,
    );
  }""")
patch(archive, '  }) async {\n    final extractDir = await Directory(',
      '  }) async {\n    await _assertCompleteArchiveSupported();\n    final extractDir = await Directory(')
patch(archive, '  }) async {\n    if (!await File(p.join(dir, SyncKeys.manifestPath)).exists()) {',
      '  }) async {\n    if (diaryStore == null) await _assertCompleteArchiveSupported();\n    if (!await File(p.join(dir, SyncKeys.manifestPath)).exists()) {')
patch('mobile/pubspec.yaml', 'version: 2.9.2+101', 'version: 2.9.2+102')
print('W9.6 archive safety gate applied; legacy data untouched')
