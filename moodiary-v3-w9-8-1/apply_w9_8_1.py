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
# A production v4 upgrade is distinct from fresh v5 and v2/v3 migrations.
# Seed the existing v4 custom tables before reopening with the v5 engine.
import_anchor = "import 'package:moodiary_data/moodiary_data.dart';"
if test.count(import_anchor) != 1 or not test.endswith("}\n"):
    raise SystemExit("Unexpected migration fixture source")
test = test.replace(import_anchor, import_anchor +
    "\nimport 'package:moodiary_data/src/mod_month_schema.dart';", 1)
v4_case = r'''
  test('W9.8 existing v4 to v5 keeps native Diary and immutable block graph', () async {
    final schema = await verifier.schemaAt(3);
    final previous = v3.DatabaseAtV3(schema.newConnection());
    await createModMonthSchema((sql) => previous.customStatement(sql));
    const id = '1c042158-916c-458e-8921-63e8529f6eb0';
    const topic = 'topic-2026-learning';
    const block = 'block-v4-legacy-0001';
    const revision = 'revision-v4-legacy-0001';
    const original = '{"type":"doc","attrs":{"v":2},"content":[]}';
    await previous.into(previous.diaries).insert(v3.DiariesCompanion.insert(
      id: id, title: 'old v4 native Diary', content: original,
      contentText: 'preserve', time: 1730950123456,
      lastModified: 1730950999888, show: 1, type: 'tiptap',
    ));
    await previous.customStatement(
      'INSERT INTO mod_month_pages'
      '(topic_id,month_key,diary_id,created_ms) VALUES(?,?,NULL,?)',
      [topic,'2026-11',42],
    );
    await previous.customStatement(
      'INSERT INTO mod_month_blocks'
      '(block_id,topic_id,month_key,kind,created_ms) VALUES(?,?,?,?,?)',
      [block,topic,'2026-11','entry',43],
    );
    await previous.customStatement(
      'INSERT INTO mod_month_revisions'
      '(revision_id,block_id,parent_revision_id,month_key,day_key,'
      'occurred_at_ms,body_json,deleted,edited_at_ms)'
      ' VALUES(?,?,NULL,?,?,?,?,?,?)',
      [revision,block,'2026-11','2026-11-07',44,original,0,45],
    );
    await previous.customStatement(
      'INSERT INTO mod_month_heads(block_id,revision_id) VALUES(?,?)',
      [block,revision],
    );
    await previous.customStatement('PRAGMA user_version = 4');
    await previous.close();

    final upgraded = MoodiaryDatabase.forTesting(schema.newConnection());
    final version = await upgraded.customSelect('PRAGMA user_version').getSingle();
    expect(version.read<int>('user_version'), 5);
    final diary = await upgraded.customSelect(
      'SELECT title,content,content_text,time,last_modified,show '
      'FROM diaries WHERE id=?',
      variables:[Variable.withString(id)],
    ).getSingle();
    expect(diary.read<String>('title'),'old v4 native Diary');
    expect(diary.read<String>('content'), original);
    expect(diary.read<String>('content_text'),'preserve');
    expect(diary.read<int>('time'),1730950123456);
    expect(diary.read<int>('last_modified'),1730950999888);
    expect(diary.read<int>('show'),1);
    final oldBlock = await upgraded.customSelect(
      'SELECT b.topic_id,b.month_key,b.created_ms,'
      'r.revision_id,r.day_key,r.body_json,r.occurred_at_ms,r.edited_at_ms '
      'FROM mod_month_blocks b JOIN mod_month_heads h ON h.block_id=b.block_id '
      'JOIN mod_month_revisions r ON r.revision_id=h.revision_id '
      'WHERE b.block_id=?',
      variables:[Variable.withString(block)],
    ).getSingle();
    expect(oldBlock.read<String>('topic_id'),topic);
    expect(oldBlock.read<String>('month_key'),'2026-11');
    expect(oldBlock.read<int>('created_ms'),43);
    expect(oldBlock.read<String>('revision_id'),revision);
    expect(oldBlock.read<String>('day_key'),'2026-11-07');
    expect(oldBlock.read<String>('body_json'),original);
    expect(oldBlock.read<int>('occurred_at_ms'),44);
    expect(oldBlock.read<int>('edited_at_ms'),45);
    final newTable = await upgraded.customSelect(
      'SELECT COUNT(*) AS n FROM mod_day_pages',
    ).getSingle();
    expect(newTable.read<int>('n'),0);
    await upgraded.close();
  });
'''
test = test[:-2] + v4_case + "\n}\n"
(root / migration).write_text(test, encoding="utf-8")

mobile_test = "mobile/test/mod_month_store_test.dart"
patch(mobile_test, "expect(db.schemaVersion, 4);", "expect(db.schemaVersion, 5);")

pub = "mobile/pubspec.yaml"
patch(pub, "version: 2.9.2+110", "version: 2.9.2+111")
print("W9.8.1 SQLite v5 day map, export safety and migration tests installed")
