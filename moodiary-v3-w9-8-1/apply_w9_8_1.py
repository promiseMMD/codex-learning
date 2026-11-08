"""W9.8.1 additive daily mapping migration; no native Diary writes.

Preserves the W9 month data model, old Diary bytes, and cloud safety gate.
All patch anchors must match exactly; never silently reapply or overwrite.
"""
from pathlib import Path
import shutil
import sys

root = Path(sys.argv[1]).resolve()
here = Path(__file__).resolve().parent
for file in (here / "overlay").rglob("*"):
    if file.is_file():
        target = root / file.relative_to(here / "overlay")
        if target.exists():
            raise SystemExit("Refuse W9.8.1 overlay conflict: " + str(target))
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(file, target)

def patch(relative, old, new):
    path = root / relative
    source = path.read_text(encoding="utf-8")
    if source.count(old) != 1:
        raise SystemExit("W9.8.1 anchor mismatch " + relative + ": " + old[:100])
    path.write_text(source.replace(old, new, 1), encoding="utf-8")

database = "packages/feature_base/moodiary_data/lib/src/db/database.dart"
patch(database, "import '../mod_month_schema.dart';",
    "import '../mod_month_schema.dart';\nimport '../mod_day_schema.dart';")
patch(database, "int get schemaVersion => 4;", "int get schemaVersion => 5;")
patch(database,
    "      await m.createAll();\n"
    "      await createModMonthSchema((sql) => customStatement(sql));",
    "      await m.createAll();\n"
    "      await createModMonthSchema((sql) => customStatement(sql));\n"
    "      await createModDaySchema((sql) => customStatement(sql));")
patch(database,
    """        if (from < 4) {
          await createModMonthSchema((sql) => customStatement(sql));
        }
      });""",
    """        if (from < 4) {
          await createModMonthSchema((sql) => customStatement(sql));
        }
        if (from < 5) {
          await createModDaySchema((sql) => customStatement(sql));
        }
      });""")
patch(database,
    "      for (final statement in modMonthClearStatements) {",
    "      for (final statement in modDayClearStatements) {\n"
    "        await customStatement(statement);\n"
    "      }\n"
    "      for (final statement in modMonthClearStatements) {")

lib = "packages/feature_base/moodiary_data/lib/moodiary_data.dart"
patch(lib, "export 'src/mod_month_graph_archive_v1.dart';",
      "export 'src/mod_month_graph_archive_v1.dart';\n"
      "export 'src/mod_day_map.dart';")

gate = "packages/feature_base/moodiary_data/lib/src/mod_month_archive_gate.dart"
patch(gate, "    'mod_month_heads', 'mod_month_ops',",
     "    'mod_month_heads', 'mod_month_ops', 'mod_day_pages',")
patch(gate,
      """'mod_month_revisions','mod_month_heads','mod_month_ops')""",
      """'mod_month_revisions','mod_month_heads','mod_month_ops',"
        "'mod_day_pages')""")
patch(gate,
      "  EXISTS(SELECT 1 FROM mod_month_pages LIMIT 1) OR",
      "  EXISTS(SELECT 1 FROM mod_day_pages LIMIT 1) OR\n"
      "  EXISTS(SELECT 1 FROM mod_month_pages LIMIT 1) OR")

graph = "packages/feature_base/moodiary_data/lib/src/mod_month_graph_archive_v1.dart"
patch(graph,
      """    final found = rows.map((r) => r.read<String>('name')).toSet();""",
      """    // W9 GraphV1 cannot encode the newer daily mapping table.
    // Its presence is allowed only while empty. Never silently omit user
    // preferences or day identity from a supposedly complete archive.
    final daySchema = await db.customSelect(
      "SELECT name FROM sqlite_master WHERE type='table' "
      "AND name='mod_day_pages'",
    ).get();
    if (daySchema.length != 1) _fail('daily_schema_missing');
    final mapped = await db.customSelect(
      'SELECT 1 AS present FROM mod_day_pages LIMIT 1',
    ).get();
    if (mapped.isNotEmpty) _fail('daily_not_in_graph_v1');
    final found = rows.map((r) => r.read<String>('name')).toSet();""")

migration = "packages/feature_base/moodiary_data/test/mod_month_migration_test.dart"
test = (root / migration).read_text(encoding="utf-8")
if test.count("expect(uv.read<int>('user_version'), 4);") != 2:
    raise SystemExit("Unexpected migration test version counts")
test = test.replace("expect(uv.read<int>('user_version'), 4);",
                    "expect(uv.read<int>('user_version'), 5);")
test = test.replace("upgrade v3 to v4", "upgrade v3 to v5")
test = test.replace("additive v4", "additive v5")
(root / migration).write_text(test, encoding="utf-8")

mobile_test = "mobile/test/mod_month_store_test.dart"
patch(mobile_test, "expect(db.schemaVersion, 4);", "expect(db.schemaVersion, 5);")

pub = "mobile/pubspec.yaml"
patch(pub, "version: 2.9.2+110", "version: 2.9.2+111")
print("W9.8.1 SQLite v5 day map, export safety and migration tests installed")
