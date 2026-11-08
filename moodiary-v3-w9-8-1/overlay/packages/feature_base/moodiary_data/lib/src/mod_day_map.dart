// W9.8.1 daily native-Diary mapping groundwork.
// No Diary creation, rewrite, cloud transfer, legacy conversion, or projection.
import 'package:drift/drift.dart';

import 'db/database.dart';

final class ModDayMapException implements Exception {
  final String code;
  const ModDayMapException(this.code);
  @override
  String toString() => 'ModDayMapException($code)';
}

final class ModDailyPage {
  final String topicId;
  final String dayKey;
  final String? diaryId;
  final bool visibleLocal;
  final int createdMs;

  const ModDailyPage({
    required this.topicId,
    required this.dayKey,
    required this.diaryId,
    required this.visibleLocal,
    required this.createdMs,
  });
}

/// A durable, one-topic/one-day mapping. Creating a *mapping* does not create
/// a native Diary or mark its block history as cloud-backed.
/// Only an unconflicted, live entry can start a day; empty and deleted
/// days are never synthesized. No ordinary Diary can be reused or modified.
final class ModDayMap {
  ModDayMap(this.db, {DateTime Function()? now})
      : _now = now ?? DateTime.now;

  final MoodiaryDatabase db;
  final DateTime Function() _now;

  static Never _fail(String code) => throw ModDayMapException(code);

  static String _topic(String topic) {
    if (!RegExp(r'^[A-Za-z0-9_-]{1,120}$').hasMatch(topic)) {
      _fail('invalid_topic');
    }
    return topic;
  }

  static String _day(String day) {
    if (!RegExp(r'^[0-9]{4}-(0[1-9]|1[0-2])-[0-9]{2}$')
        .hasMatch(day)) _fail('invalid_day');
    final y = int.parse(day.substring(0, 4));
    final m = int.parse(day.substring(5, 7));
    final d = int.parse(day.substring(8, 10));
    if (y < 1 || DateTime.utc(y, m, d).year != y ||
        DateTime.utc(y, m, d).month != m ||
        DateTime.utc(y, m, d).day != d) {
      _fail('invalid_day');
    }
    return day;
  }

  static ModDailyPage _decode(QueryRow row) {
    final topic = _topic(row.read<String>('topic_id'));
    final day = _day(row.read<String>('day_key'));
    final local = row.read<int>('visible_local');
    final created = row.read<int>('created_ms');
    if ((local != 0 && local != 1) || created < 0) {
      _fail('daily_mapping_corrupt');
    }
    return ModDailyPage(
      topicId: topic,
      dayKey: day,
      diaryId: row.readNullable<String>('diary_id'),
      visibleLocal: local == 1,
      createdMs: created,
    );
  }

  Future<ModDailyPage?> readDay({
    required String topicId,
    required String dayKey,
  }) async {
    final topic = _topic(topicId), day = _day(dayKey);
    final rows = await db.customSelect(
      'SELECT topic_id,day_key,diary_id,visible_local,created_ms'
      ' FROM mod_day_pages WHERE topic_id = ? AND day_key = ?',
      variables: [Variable.withString(topic), Variable.withString(day)],
    ).get();
    if (rows.isEmpty) return null;
    if (rows.length != 1) _fail('duplicate_daily_mapping');
    return _decode(rows.single);
  }

  Future<List<ModDailyPage>> readTopic(String topicId) async {
    final topic = _topic(topicId);
    final rows = await db.customSelect(
      'SELECT topic_id,day_key,diary_id,visible_local,created_ms'
      ' FROM mod_day_pages WHERE topic_id = ? ORDER BY day_key DESC',
      variables: [Variable.withString(topic)],
    ).get();
    return List<ModDailyPage>.unmodifiable(rows.map(_decode));
  }

  /// Only create an index entry if a current *single-head*, non-deleted
  /// entry belongs to the exact day. Summary and historical revisions do
  /// not authorize a new daily page. All checks and insertion are atomic.
  Future<ModDailyPage> ensureFromLiveBlock({
    required String topicId,
    required String dayKey,
  }) async {
    final topic = _topic(topicId), day = _day(dayKey);
    return db.transaction(() async {
      final live = await db.customSelect(
        'SELECT b.block_id,COUNT(h.revision_id) AS heads,'
        ' SUM(CASE WHEN r.deleted=0 AND r.day_key=?'
        ' AND r.month_key=? THEN 1 ELSE 0 END) AS valid_heads'
        ' FROM mod_month_blocks b'
        ' LEFT JOIN mod_month_heads h ON h.block_id=b.block_id'
        ' LEFT JOIN mod_month_revisions r ON r.revision_id=h.revision_id'
        " WHERE b.topic_id=? AND b.month_key=? AND b.kind='entry'"
        ' GROUP BY b.block_id',
        variables: [
          Variable.withString(day),
          Variable.withString(day.substring(0, 7)),
          Variable.withString(topic),
          Variable.withString(day.substring(0, 7)),
        ],
      ).get();
      var allowed = false;
      for (final row in live) {
        final heads = row.read<int>('heads');
        if (heads != 1) _fail('conflicting_daily_block_heads');
        if (row.read<int>('valid_heads') == 1) allowed = true;
      }
      if (!allowed) _fail('no_live_entry_for_day');
      final now = _now().toUtc().millisecondsSinceEpoch;
      if (now < 0) _fail('invalid_created_time');
      await db.customStatement(
        'INSERT OR IGNORE INTO mod_day_pages'
        ' (topic_id,day_key,diary_id,visible_local,created_ms)'
        ' VALUES(?,?,NULL,1,?)',
        [topic, day, now],
      );
      final stored = await readDay(topicId: topic, dayKey: day);
      if (stored == null) _fail('daily_mapping_missing');
      return stored;
    });
  }

  /// Local-only preference. Does not change Diary.show or affect any cloud
  /// content; do not confuse this with synced or backed-up state.
  Future<ModDailyPage> setLocalVisibility({
    required String topicId,
    required String dayKey,
    required bool visible,
  }) async {
    final topic = _topic(topicId), day = _day(dayKey);
    return db.transaction(() async {
      final stored = await readDay(topicId: topic, dayKey: day);
      if (stored == null) _fail('daily_mapping_missing');
      await db.customStatement(
        'UPDATE mod_day_pages SET visible_local=?'
        ' WHERE topic_id=? AND day_key=?',
        [visible ? 1 : 0, topic, day],
      );
      return (await readDay(topicId: topic, dayKey: day))!;
    });
  }
}
