// W9.8.2: non-destructive home preview of W9 daily record blocks.
// It never writes to the native Diary table or claims cloud/ZIP coverage.
import 'package:moodiary_data/moodiary_data.dart';
import 'package:drift/drift.dart';

import 'mod_month_day_preview.dart';
import 'mod_month_store.dart';

typedef ModDailyTopicTitle = Future<String?> Function(String topicId);

final class ModHomeDay {
  final String topicId;
  final String topicTitle;
  final String dayKey;
  final int count;
  final String preview;
  final bool visibleLocal;
  const ModHomeDay({
    required this.topicId,
    required this.topicTitle,
    required this.dayKey,
    required this.count,
    required this.preview,
    required this.visibleLocal,
  });
}

/// Read-only projection, one row per topic + natural calendar day.
/// Ordinary Diaries stay separate until a complete archive/restore version
/// can represent day identity, blocks, revisions, tombstones and assets.
final class ModDailyHomeIndex {
  final ModMonthStore store;
  final ModDayMap dayMap;
  final ModDailyTopicTitle topicTitle;
  const ModDailyHomeIndex({
    required this.store,
    required this.dayMap,
    required this.topicTitle,
  });

  static const maxTopicMonths = 512;

  /// A failed or ambiguous read rejects the *whole* daily preview. It must
  /// never be mistaken for an empty, fully backed-up set of records.
  Future<List<ModHomeDay>> load() => store.db.transaction(() async {
    final groups = await store.db.customSelect(
      "SELECT DISTINCT topic_id,month_key FROM mod_month_blocks "
      "WHERE kind='entry' ORDER BY month_key DESC,topic_id ASC LIMIT 513",
    ).get();
    if (groups.length > maxTopicMonths) {
      throw StateError('daily_home_too_many_months');
    }

    final titles = <String,String?>{};
    final preferences = <String,Map<String,ModDailyPage>>{};
    final result = <ModHomeDay>[];
    final seen = <String>{};

    for (final row in groups) {
      final topic = row.read<String>('topic_id');
      final month = row.read<String>('month_key');
      if (!titles.containsKey(topic)) {
        titles[topic] = await topicTitle(topic);
      }
      final title = titles[topic];
      // A hidden or deleted topic is not promoted into a separate Diary.
      if (title == null) continue;
      if (!preferences.containsKey(topic)) {
        final saved = await dayMap.readTopic(topic);
        preferences[topic] = {for (final p in saved) p.dayKey: p};
      }
      final blocks = await store.readMonth(
        topicId: topic, monthKey: month, includeDeleted: true);
      final previews = buildModDayPreviews(
        topicId: topic, monthKey: month, blocks: blocks);
      for (final day in previews) {
        final key = topic + '|' + day.dayKey;
        if (!seen.add(key)) throw StateError('duplicate_home_day');
        final saved = preferences[topic]![day.dayKey];
        if (saved?.diaryId != null) {
          // A future native projection must use a dedicated edit route and
          // non-legacy archive protocol. Never show the same day twice.
          throw StateError('daily_native_binding_requires_new_projection');
        }
        result.add(ModHomeDay(
          topicId: topic,
          topicTitle: title,
          dayKey: day.dayKey,
          count: day.count,
          preview: day.previewText,
          visibleLocal: saved?.visibleLocal ?? true,
        ));
      }
    }
    result.sort((a,b) {
      final date = b.dayKey.compareTo(a.dayKey);
      return date == 0 ? a.topicId.compareTo(b.topicId) : date;
    });
    return List<ModHomeDay>.unmodifiable(result);
  });

  /// A local visibility preference is the only write allowed here.
  /// It creates a day mapping only after verifying a still-live single head.
  /// No hidden flag is propagated to ordinary Diary.show or cloud sync.
  Future<void> setVisible(ModHomeDay day, bool visible) async {
    await dayMap.ensureFromLiveBlock(
      topicId: day.topicId, dayKey: day.dayKey);
    await dayMap.setLocalVisibility(
      topicId: day.topicId, dayKey: day.dayKey, visible: visible);
  }
}
