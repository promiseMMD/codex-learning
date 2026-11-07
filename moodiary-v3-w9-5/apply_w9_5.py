"""W9.5.1: read-only daily previews; no native Diary projection or sync change."""
from pathlib import Path
import shutil
import sys

root = Path(sys.argv[1]).resolve()
here = Path(__file__).resolve().parent

for relative in (
    "mobile/lib/app/home/mod_month_day_preview.dart",
    "mobile/test/mod_month_day_preview_test.dart",
):
    src = here / "overlay" / relative
    dst = root / relative
    if not src.is_file() or dst.exists():
        raise SystemExit("W9.5 source missing or existing destination: " + relative)
    dst.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(src, dst)

def patch(path, old, new):
    p = root / path
    text = p.read_text(encoding="utf-8")
    if text.count(old) != 1:
        raise SystemExit("W9.5 anchor drift (" + str(text.count(old)) + "): " + path)
    p.write_text(text.replace(old, new, 1), encoding="utf-8")

patch("mobile/pubspec.yaml", "version: 2.9.2+99", "version: 2.9.2+100")
path = "mobile/lib/app/home/mod_month_page.dart"
patch(path, "import 'mod_month_updates.dart';",
      "import 'mod_month_updates.dart';\nimport 'mod_month_day_preview.dart';")
patch(path, "    final shown = entries.take(_limit).toList();",
      """    final shown = entries.take(_limit).toList();
    final previews = snapshot == null
        ? const <ModDayPreview>[]
        : buildModDayPreviews(
            topicId: widget.topicId, monthKey: _month, blocks: blocks);
    final previewByDay = <String, ModDayPreview>{
      for (final item in previews) item.dayKey: item,
    };""")
patch(path, """              Padding(padding: const EdgeInsets.all(12),
                child: Text(shown[i].dayKey ?? l10n.month.summary)),""",
      """              Padding(padding: const EdgeInsets.all(12),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(shown[i].dayKey ?? l10n.month.summary),
                    if (!_recycle && _query.isEmpty &&
                        previewByDay.containsKey(shown[i].dayKey))
                      Text(
                        (previewByDay[shown[i].dayKey]?.count ?? 0).toString() +
                            ' · ' +
                            (previewByDay[shown[i].dayKey]?.previewText ?? ''),
                        maxLines: 2, overflow: TextOverflow.ellipsis,
                        style: context.theme.typography.bodySmall.secondary,
                      ),
                  ])),""")
patch("mobile/test/mod_month_page_test.dart",
      "    expect(find.text('cached native record'),findsOneWidget);",
      """    expect(find.text('cached native record'),findsOneWidget);
    expect(find.text('1 · cached native record'), findsOneWidget);""")
print("W9.5.1 applied: read-only day previews and 6 regressions; no Diary writes, no cloud claim")
