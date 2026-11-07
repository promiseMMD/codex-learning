import 'dart:convert';

import 'package:moodiary_data/moodiary_data.dart';
import 'package:moodiary_models/moodiary_models.dart';

import 'mod_continuous.dart' show ModDiary;
import 'mod_lan_rich.dart';
import 'mod_month_store.dart';

String modMonthKey(DateTime value) =>
    '${value.year.toString().padLeft(4, '0')}-${value.month.toString().padLeft(2, '0')}';
String modDayKey(DateTime value) =>
    '${modMonthKey(value)}-${value.day.toString().padLeft(2, '0')}';

/// One immutable operation. A retry must reuse this entire object, including IDs.
class ModMonthMutation {
  final String operationId;
  final String revisionId;
  final String blockId;
  final String topicId;
  final String monthKey;
  final String kind;
  final String? parentRevisionId;
  final String? dayKey;
  final int occurredAtMs;
  final String tiptapJson;
  final bool deleted;

  const ModMonthMutation({
    required this.operationId, required this.revisionId, required this.blockId,
    required this.topicId, required this.monthKey, required this.kind,
    required this.parentRevisionId, required this.dayKey,
    required this.occurredAtMs, required this.tiptapJson, this.deleted = false,
  });

  factory ModMonthMutation.fromBlock(ModStoredBlock block, {
    required String operationId, required String revisionId,
    required bool deleted,
  }) => ModMonthMutation(
    operationId: operationId, revisionId: revisionId, blockId: block.blockId,
    topicId: block.topicId, monthKey: block.monthKey, kind: block.kind,
    parentRevisionId: block.revisionId, dayKey: block.dayKey,
    occurredAtMs: block.occurredAtMs, tiptapJson: block.tiptapJson,
    deleted: deleted,
  );

  Map<String, Object?> toJson() => {
    'schemaVersion': 1, 'topicId': topicId, 'monthKey': monthKey,
    'operationId': operationId, 'revisionId': revisionId, 'blockId': blockId,
    'kind': kind, 'parentRevisionId': parentRevisionId, 'dayKey': dayKey,
    'occurredAtMs': occurredAtMs, 'document': jsonDecode(tiptapJson),
    'deleted': deleted,
  };
}

class ModNativeMonthSnapshot {
  final Diary topic;
  final String monthKey;
  final List<String> months;
  final List<ModStoredBlock> blocks;
  final int legacyCount;
  ModNativeMonthSnapshot({required this.topic, required this.monthKey,
    required Iterable<String> months, required Iterable<ModStoredBlock> blocks,
    required this.legacyCount,
  }) : months = List.unmodifiable(months), blocks = List.unmodifiable(blocks);
}

/// Same DB connection and CAS store as the PC HTTP handler; never creates a
/// temporary Diary, projection, technical tag or cloud-sync acknowledgement.
class ModNativeMonthRepository {
  final ModMonthStore store;
  final DiaryRepository diaries;
  final void Function(String topicId)? onCommitted;
  ModNativeMonthRepository({required this.store, required this.diaries,
    this.onCommitted});

  Future<Diary> _topic(String id) async {
    final topic = await diaries.getDiaryByBusinessId(id);
    if (topic == null || !topic.show || !ModDiary.isTopic(topic)) {
      throw const ModMonthStoreException('topic_not_available');
    }
    return topic;
  }

  Future<ModNativeMonthSnapshot> load(String topicId, String monthKey) =>
      store.db.transaction(() async {
    final topic = await _topic(topicId);
    final blocks = await store.readMonth(topicId: topicId, monthKey: monthKey,
      includeDeleted: true);
    for (final block in blocks) {
      ModLanRichDocument.validate(jsonDecode(block.tiptapJson));
      // A corrupt/imported timestamp or date must fail this snapshot before
      // native date widgets can throw or normalize it into another archive day.
      if (block.occurredAtMs < 0) {
        throw const ModMonthStoreException('invalid_event_time');
      }
      try { DateTime.fromMillisecondsSinceEpoch(block.occurredAtMs); }
      catch (_) { throw const ModMonthStoreException('invalid_event_time'); }
      final day = block.dayKey;
      if (block.kind == 'entry') {
        final parsed = day == null ? null : DateTime.tryParse(day);
        if (parsed == null || modDayKey(parsed) != day ||
            !day!.startsWith('$monthKey-')) {
          throw const ModMonthStoreException('invalid_record_day');
        }
      } else if (block.kind != 'summary' || day != null) {
        throw const ModMonthStoreException('invalid_block_kind');
      }
    }
    final months = {...await store.monthKeysForTopic(topicId), monthKey}.toList()
      ..sort((a, b) => b.compareTo(a));
    for (final key in months) {
      final date = DateTime.tryParse('$key-01');
      if (!RegExp(r'^[0-9]{4}-(0[1-9]|1[0-2])$').hasMatch(key) ||
          date == null || date.year < 1 || modMonthKey(date) != key) {
        throw const ModMonthStoreException('invalid_month_index');
      }
    }
    final all = await diaries.getAllDiaries();
    return ModNativeMonthSnapshot(topic: topic, monthKey: monthKey,
      months: months, blocks: blocks,
      legacyCount: all.where((d) => d.show &&
        ModDiary.topicIdOf(d) == topicId).length);
  });

  Future<ModStoredBlock> commit(ModMonthMutation operation) async {
    final saved = await store.db.transaction(() async {
      await _topic(operation.topicId);
      return store.appendRevision(
        operationId: operation.operationId, blockId: operation.blockId,
        revisionId: operation.revisionId, topicId: operation.topicId,
        monthKey: operation.monthKey, kind: operation.kind,
        parentRevisionId: operation.parentRevisionId, dayKey: operation.dayKey,
        occurredAtMs: operation.occurredAtMs, tiptapJson: operation.tiptapJson,
        deleted: operation.deleted,
      );
    });
    try { onCommitted?.call(operation.topicId); }
    catch (_) { /* A notification cannot invalidate a committed write. */ }
    return saved;
  }
}

String modBlockText(String json) {
  final text = StringBuffer();
  void visit(Object? node) {
    if (node is! Map) return;
    if (node['type'] == 'text') text.write(node['text']);
    if (node['type'] == 'hardBreak') text.writeln();
    if (node['content'] case final List content) {
      for (final child in content) { visit(child); }
    }
    if (node['type'] == 'paragraph' || node['type'] == 'heading') text.writeln();
  }
  visit(jsonDecode(json));
  return text.toString().trim();
}
