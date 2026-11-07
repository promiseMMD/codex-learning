"""W9.1 additive SQLite v4 migration and monthly block store overlay.

Applied AFTER W8.5 source patches; no existing old diary is imported or edited.
This intentionally uses explicit custom SQL tables in schema v4. The current
Drift-generated v3 tables remain untouched; their published upgrade scripts
still run unmodified from v1/v2 to v3 before W9 schema installation.
"""
from pathlib import Path
import shutil
import sys

root = Path(sys.argv[1]).resolve() if len(sys.argv)>1 else Path.cwd()
here = Path(__file__).resolve().parent

for relative in [
    "packages/feature_base/moodiary_data/lib/src/mod_month_schema.dart",
    "mobile/lib/app/home/mod_month_store.dart",
    "mobile/test/mod_month_store_test.dart",
    "packages/feature_base/moodiary_data/test/mod_month_migration_test.dart",
]:
    src=here/"overlay"/relative
    dst=root/relative
    if not src.is_file() or dst.exists():
        raise SystemExit(f"W9 source missing or overwrite refused: {relative}")
    dst.parent.mkdir(parents=True,exist_ok=True)
    shutil.copyfile(src,dst)

p=root/"packages/feature_base/moodiary_data/lib/src/db/database.dart"
s=p.read_text(encoding="utf-8")
def one(a,b):
    global s
    n=s.count(a)
    if n!=1:
        raise SystemExit(f"W9 database migration anchor drift ({n}): {a[:95]!r}")
    s=s.replace(a,b,1)

one(
    "import 'db_codec.dart';",
    "import 'db_codec.dart';\nimport '../mod_month_schema.dart';",
)
one("int get schemaVersion => 3;", "int get schemaVersion => 4;")
one(
    "      await m.createAll();",
    "      await m.createAll();\n"
    "      await createModMonthSchema((sql) => customStatement(sql));",
)
one(
    """      return transaction(
        () => m.runMigrationSteps(
          from: from,
          to: to,
          steps: migrationSteps(""",
    """      return transaction(() async {
        // Keep published v1→v2→v3 migrations byte-for-byte intact.
        if (from < 3) {
          await m.runMigrationSteps(
            from: from,
            to: 3,
            steps: migrationSteps(""",
)
one(
    """            },
          ),
        ),
      );
    },
""",
    """            },
            ),
          );
        }
        if (from < 4) {
          await createModMonthSchema((sql) => customStatement(sql));
        }
      });
    },
""",
)
one(
    "      await customStatement('PRAGMA defer_foreign_keys = ON');",
    "      await customStatement('PRAGMA defer_foreign_keys = ON');\n"
    "      for (final statement in modMonthClearStatements) {\n"
    "        await customStatement(statement);\n"
    "      }",
)
p.write_text(s,encoding="utf-8")
print("W9.1 schema v4: fresh install, old v3 upgrade, and full-reset hooks installed")
