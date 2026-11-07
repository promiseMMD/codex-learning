// W9.5.1: read-only per-day previews for the native month workspace.
// No Diary writes, no WebDAV sync/backup status, no migration.
import 'mod_month_native.dart' show modBlockText;
import 'mod_month_store.dart';

class ModDayPreview {
  final String topicId;
  final String monthKey;
  final String dayKey;
  final int count;
  final List<ModStoredBlock> recent;

  ModDayPreview({
    required this.topicId,
    required this.monthKey,
    required this.dayKey,
    required this.count,
    required Iterable<ModStoredBlock> recent,
  }) : recent = List<ModStoredBlock>.unmodifiable(recent);

  /// Display-only text. Never persist this truncated/flattened representation.
  String get previewText => recent
      .map((block) => modBlockText(block.tiptapJson))
      .where((text) => text.isNotEmpty)
      .join(' · ');
}

/// One row per logical day. The last 3 entries in event-time ordering are
/// displayed in ascending order. editedAt never changes their ordering.
/// Deletions and monthly summaries are excluded; corrupt/mixed snapshots fail
/// closed instead of silently generating misleading preview cards.
List<ModDayPreview> buildModDayPreviews({
  required String topicId,
  required String monthKey,
  required Iterable<ModStoredBlock> blocks,
}) {
  if (!RegExp(r'^[0-9]{4}-(0[1-9]|1[0-2])$').hasMatch(monthKey)) {
    throw StateError('invalid_preview_month');
  }
  final grouped = <String, List<ModStoredBlock>>{};
  final ids = <String>{};
  for (final block in blocks) {
    if (block.topicId != topicId || block.monthKey != monthKey) {
      throw StateError('mixed_preview_snapshot');
    }
    if (!ids.add(block.blockId)) {
      throw StateError('duplicate_preview_block');
    }
    if (block.kind == 'summary') {
      if (block.dayKey != null) throw StateError('invalid_summary_day');
      continue;
    }
    if (block.kind != 'entry') throw StateError('unknown_preview_kind');
    final day = block.dayKey;
    if (day == null ||
        !RegExp(r'^[0-9]{4}-[0-9]{2}-[0-9]{2}$').hasMatch(day) ||
        !day.startsWith('$monthKey-')) {
      throw StateError('invalid_preview_day');
    }
    final y = int.parse(day.substring(0, 4));
    final m = int.parse(day.substring(5, 7));
    final d = int.parse(day.substring(8, 10));
    final canonical = DateTime.utc(y, m, d);
    if (canonical.year != y || canonical.month != m || canonical.day != d) {
      throw StateError('invalid_preview_day');
    }
    if (block.deleted) continue;
    grouped.putIfAbsent(day, () => <ModStoredBlock>[]).add(block);
  }

  final days = grouped.keys.toList()..sort((a, b) => b.compareTo(a));
  return List<ModDayPreview>.unmodifiable(days.map((day) {
    final ordered = grouped[day]!..sort((a, b) {
      final event = a.occurredAtMs.compareTo(b.occurredAtMs);
      return event != 0 ? event : a.blockId.compareTo(b.blockId);
    });
    return ModDayPreview(
      topicId: topicId,
      monthKey: monthKey,
      dayKey: day,
      count: ordered.length,
      recent: ordered.skip(ordered.length > 3 ? ordered.length - 3 : 0),
    );
  }));
}
