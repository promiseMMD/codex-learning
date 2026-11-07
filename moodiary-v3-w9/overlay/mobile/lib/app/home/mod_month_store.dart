// W9.1 durable month blocks. Uses Moodiary's existing v4 SQLite DB and
// Drift transaction boundary, not an independent or unsynced database.
// W9.1 is NOT wired to the end-user month UI or WebDAV until adapter tests pass.
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart';
import 'package:moodiary_data/moodiary_data.dart';
import 'package:moodiary_utils/moodiary_utils.dart';

import 'mod_lan_rich.dart';

class ModMonthStoreException implements Exception {
  final String code;
  const ModMonthStoreException(this.code);

  @override
  String toString() => 'ModMonthStoreException($code)';
}

class ModStoredMonth {
  final String topicId;
  final String monthKey;
  final String? diaryId;

  const ModStoredMonth({
    required this.topicId,
    required this.monthKey,
    required this.diaryId,
  });
}

class ModStoredBlock {
  final String blockId;
  final String revisionId;
  final String? parentRevisionId;
  final String topicId;
  final String monthKey;
  final String kind;
  final String? dayKey;
  final int occurredAtMs;
  final int editedAtMs;
  final String tiptapJson;
  final bool deleted;

  const ModStoredBlock({
    required this.blockId,
    required this.revisionId,
    required this.parentRevisionId,
    required this.topicId,
    required this.monthKey,
    required this.kind,
    required this.dayKey,
    required this.occurredAtMs,
    required this.editedAtMs,
    required this.tiptapJson,
    required this.deleted,
  });
}

/// Durable local revisions, explicitly refusing silent last-writer-wins.
/// Imported divergent branches are reserved for a separate WebDAV merge
/// adapter and must never be silently reduced to one head.
class ModMonthStore {
  final MoodiaryDatabase db;
  final DateTime Function() _now;

  ModMonthStore(this.db, {DateTime Function()? clock})
      : _now = clock ?? DateTime.now;

  static const _topicPattern = r'^[a-zA-Z0-9_-]{1,120}$';
  static const _idPattern = r'^[a-zA-Z0-9_-]{8,120}$';

  static Never _bad(String code) => throw ModMonthStoreException(code);

  static String _identifier(Object? raw, String code,
      {String pattern = _idPattern}) {
    if (raw is! String || !RegExp(pattern).hasMatch(raw)) _bad(code);
    return raw;
  }

  static String _month(String raw) {
    if (!RegExp(r'^[0-9]{4}-[0-9]{2}$').hasMatch(raw)) {
      _bad('invalid_month');
    }
    final year = int.parse(raw.substring(0, 4));
    final month = int.parse(raw.substring(5, 7));
    if (year < 1 || month < 1 || month > 12) _bad('invalid_month');
    return raw;
  }

  static String? _day(String? raw, String month, String kind) {
    if (kind == 'summary') {
      if (raw != null) _bad('summary_must_not_have_day');
      return null;
    }
    if (raw == null || !RegExp(r'^[0-9]{4}-[0-9]{2}-[0-9]{2}$').hasMatch(raw) ||
        !raw.startsWith('$month-')) {
      _bad('invalid_record_day');
    }
    final y = int.parse(raw.substring(0, 4));
    final m = int.parse(raw.substring(5, 7));
    final d = int.parse(raw.substring(8, 10));
    final date = DateTime.utc(y, m, d);
    if (date.year != y || date.month != m || date.day != d) {
      _bad('invalid_record_day');
    }
    return raw;
  }

  Future<ModStoredMonth> ensureMonth({
    required String topicId,
    required String monthKey,
  }) async {
    final topic = _identifier(topicId, 'invalid_topic', pattern: _topicPattern);
    final month = _month(monthKey);
    return db.transaction(() async => _ensureMonth(topic, month));
  }

  Future<ModStoredMonth> _ensureMonth(String topic, String month) async {
    await db.customStatement(
      'INSERT OR IGNORE INTO mod_month_pages'
      ' (topic_id,month_key,diary_id,created_ms) VALUES (?,?,NULL,?)',
      [topic, month, _now().toUtc().millisecondsSinceEpoch],
    );
    final rows = await db.customSelect(
      'SELECT diary_id FROM mod_month_pages'
      ' WHERE topic_id = ? AND month_key = ?',
      variables: [
        Variable.withString(topic),
        Variable.withString(month),
      ],
    ).get();
    if (rows.length != 1) _bad('month_mapping_invariant');
    return ModStoredMonth(
      topicId: topic,
      monthKey: month,
      diaryId: rows.single.readNullable<String>('diary_id'),
    );
  }

  /// Attach a canonical, already-existing native Diary id to the month.
  /// This never creates or modifies an ordinary Diary, and cannot rebind a
  /// month to another Diary or reuse an already-bound Diary.
  Future<void> bindExistingDiary({
    required String topicId,
    required String monthKey,
    required String diaryId,
  }) async {
    final topic = _identifier(topicId, 'invalid_topic', pattern: _topicPattern);
    final month = _month(monthKey);
    final id = _identifier(diaryId, 'invalid_diary_id');
    await db.transaction(() async {
      await _ensureMonth(topic, month);
      final exists = await db.customSelect(
        'SELECT 1 AS present FROM diaries WHERE id = ? LIMIT 1',
        variables: [Variable.withString(id)],
      ).get();
      if (exists.isEmpty) _bad('native_diary_not_found');

      final now = await db.customSelect(
        'SELECT diary_id FROM mod_month_pages'
        ' WHERE topic_id = ? AND month_key = ?',
        variables: [
          Variable.withString(topic),
          Variable.withString(month),
        ],
      ).get();
      final bound = now.single.readNullable<String>('diary_id');
      if (bound == id) return;
      if (bound != null) _bad('month_already_bound');

      final other = await db.customSelect(
        'SELECT 1 AS present FROM mod_month_pages WHERE diary_id = ?',
        variables: [Variable.withString(id)],
      ).get();
      if (other.isNotEmpty) _bad('diary_already_bound');
      await db.customStatement(
        'UPDATE mod_month_pages SET diary_id = ?'
        ' WHERE topic_id = ? AND month_key = ? AND diary_id IS NULL',
        [id, topic, month],
      );
    });
  }

  /// CAS append. Same operationId + same payload is idempotent.
  ///
  /// A new block uses parentRevisionId=null. Edits, deletion tombstones and
  /// cross-month moves require the *current* parent head, or fail with stale.
  /// For summaries there can be only one block per topic-month.
  Future<ModStoredBlock> appendRevision({
    required String operationId,
    required String blockId,
    required String revisionId,
    required String topicId,
    required String monthKey,
    required String kind,
    required String? parentRevisionId,
    required String? dayKey,
    required int occurredAtMs,
    required String tiptapJson,
    bool deleted = false,
  }) async {
    final operation = _identifier(operationId, 'invalid_operation_id');
    final block = _identifier(blockId, 'invalid_block_id');
    final revision = _identifier(revisionId, 'invalid_revision_id');
    final topic = _identifier(topicId, 'invalid_topic', pattern: _topicPattern);
    final month = _month(monthKey);
    if (kind != 'entry' && kind != 'summary') _bad('invalid_block_kind');
    final day = _day(dayKey, month, kind);
    final parent = parentRevisionId == null ? null :
        _identifier(parentRevisionId, 'invalid_parent_revision_id');
    if (occurredAtMs < 0) _bad('invalid_event_time');
    if (parent == revision) _bad('revision_self_parent');

    // W6's supported rich subset is the only editable type for this first
    // milestone. The original JSON is preserved exactly after validation.
    try {
      ModLanRichDocument.validate(jsonDecode(tiptapJson));
    } catch (_) {
      _bad('unsupported_block_document');
    }

    final payload = jsonEncode([
      block, revision, topic, month, kind, parent, day,
      occurredAtMs, tiptapJson, deleted,
    ]);
    final fingerprint = sha256.convert(utf8.encode(payload)).toString();

    return db.transaction(() async {
      final oldOps = await db.customSelect(
        'SELECT payload_sha256,block_id,revision_id FROM mod_month_ops'
        ' WHERE operation_id = ?',
        variables: [Variable.withString(operation)],
      ).get();
      if (oldOps.isNotEmpty) {
        final old = oldOps.single;
        if (old.read<String>('payload_sha256') != fingerprint ||
            old.read<String>('block_id') != block ||
            old.read<String>('revision_id') != revision) {
          _bad('operation_id_collision');
        }
        return _readRevision(block, revision, topic);
      }

      final reusedRevision = await db.customSelect(
        'SELECT 1 AS present FROM mod_month_revisions WHERE revision_id = ?',
        variables: [Variable.withString(revision)],
      ).get();
      if (reusedRevision.isNotEmpty) _bad('revision_id_collision');

      final oldBlocks = await db.customSelect(
        'SELECT topic_id,month_key,kind FROM mod_month_blocks'
        ' WHERE block_id = ?',
        variables: [Variable.withString(block)],
      ).get();

      if (oldBlocks.isEmpty) {
        if (parent != null) _bad('unknown_block_parent');
        if (kind == 'summary') {
          final summary = await db.customSelect(
            'SELECT 1 AS present FROM mod_month_blocks'
            " WHERE topic_id = ? AND month_key = ? AND kind = 'summary'",
            variables: [Variable.withString(topic), Variable.withString(month)],
          ).get();
          if (summary.isNotEmpty) _bad('summary_already_exists');
        }
        await _ensureMonth(topic, month);
        await db.customStatement(
          'INSERT INTO mod_month_blocks'
          ' (block_id,topic_id,month_key,kind,created_ms) VALUES (?,?,?,?,?)',
          [block, topic, month, kind,
            _now().toUtc().millisecondsSinceEpoch],
        );
      } else {
        if (parent == null) _bad('duplicate_block_root');
        final old = oldBlocks.single;
        if (old.read<String>('topic_id') != topic ||
            old.read<String>('kind') != kind) {
          _bad('block_identity_conflict');
        }
        final heads = await db.customSelect(
          'SELECT revision_id FROM mod_month_heads WHERE block_id = ?',
          variables: [Variable.withString(block)],
        ).get();
        if (heads.length != 1) _bad('block_conflicted_or_missing_head');
        if (heads.single.read<String>('revision_id') != parent) {
          _bad('stale_revision');
        }
        final parentRows = await db.customSelect(
          'SELECT block_id FROM mod_month_revisions WHERE revision_id = ?',
          variables: [Variable.withString(parent)],
        ).get();
        if (parentRows.length != 1 ||
            parentRows.single.read<String>('block_id') != block) {
          _bad('cross_block_parent');
        }

        if (old.read<String>('month_key') != month) {
          if (kind == 'summary') _bad('summary_cannot_move_month');
          await _ensureMonth(topic, month);
          // Parent and new revision both stay in the immutable history.
          await db.customStatement(
            'UPDATE mod_month_blocks SET month_key = ? WHERE block_id = ?',
            [month, block],
          );
        }
      }

      final edited = _now().toUtc().millisecondsSinceEpoch;
      await db.customStatement(
        'INSERT INTO mod_month_revisions'
        ' (revision_id,block_id,parent_revision_id,month_key,day_key,'
        ' occurred_at_ms,body_json,deleted,edited_at_ms)'
        ' VALUES (?,?,?,?,?,?,?,?,?)',
        [revision, block, parent, month, day, occurredAtMs,
          tiptapJson, deleted ? 1 : 0, edited],
      );
      if (parent != null) {
        await db.customStatement(
          'DELETE FROM mod_month_heads'
          ' WHERE block_id = ? AND revision_id = ?',
          [block, parent],
        );
      }
      await db.customStatement(
        'INSERT INTO mod_month_heads (block_id,revision_id) VALUES (?,?)',
        [block, revision],
      );
      await db.customStatement(
        'INSERT INTO mod_month_ops'
        ' (operation_id,payload_sha256,block_id,revision_id,applied_at_ms)'
        ' VALUES (?,?,?,?,?)',
        [operation, fingerprint, block, revision, edited],
      );
      return _readRevision(block, revision, topic);
    });
  }

  Future<ModStoredBlock> _readRevision(
    String blockId, String revisionId, String topic,
  ) async {
    final rows = await db.customSelect(
      'SELECT b.block_id,b.topic_id,b.kind,'
      ' r.revision_id,r.parent_revision_id,r.month_key,r.day_key,'
      ' r.occurred_at_ms,r.body_json,r.deleted,r.edited_at_ms'
      ' FROM mod_month_blocks b JOIN mod_month_revisions r'
      ' ON b.block_id = r.block_id'
      ' WHERE b.block_id = ? AND r.revision_id = ?',
      variables: [Variable.withString(blockId), Variable.withString(revisionId)],
    ).get();
    if (rows.length != 1) _bad('stored_revision_missing');
    final row = rows.single;
    if (row.read<String>('topic_id') != topic) _bad('topic_mismatch');
    return _decode(row);
  }

  static ModStoredBlock _decode(QueryRow r) => ModStoredBlock(
    blockId: r.read<String>('block_id'),
    revisionId: r.read<String>('revision_id'),
    parentRevisionId: r.readNullable<String>('parent_revision_id'),
    topicId: r.read<String>('topic_id'),
    monthKey: r.read<String>('month_key'),
    kind: r.read<String>('kind'),
    dayKey: r.readNullable<String>('day_key'),
    occurredAtMs: r.read<int>('occurred_at_ms'),
    editedAtMs: r.read<int>('edited_at_ms'),
    tiptapJson: r.read<String>('body_json'),
    deleted: r.read<int>('deleted') != 0,
  );

  Future<List<ModStoredBlock>> readMonth({
    required String topicId, required String monthKey,
    bool includeDeleted = false,
  }) async {
    final topic = _identifier(topicId, 'invalid_topic', pattern: _topicPattern);
    final month = _month(monthKey);
    final rows = await db.customSelect(
      'SELECT b.block_id,b.topic_id,b.kind,'
      ' r.revision_id,r.parent_revision_id,r.month_key,r.day_key,'
      ' r.occurred_at_ms,r.body_json,r.deleted,r.edited_at_ms'
      ' FROM mod_month_blocks b'
      ' JOIN mod_month_heads h ON b.block_id = h.block_id'
      ' JOIN mod_month_revisions r ON h.revision_id = r.revision_id'
      ' WHERE b.topic_id = ? AND b.month_key = ?'
      ' ORDER BY r.occurred_at_ms ASC, b.block_id ASC',
      variables: [Variable.withString(topic), Variable.withString(month)],
    ).get();
    final ids = <String>{};
    final out = <ModStoredBlock>[];
    for (final row in rows) {
      final value = _decode(row);
      if (!ids.add(value.blockId)) {
        _bad('block_has_multiple_heads');
      }
      if (value.monthKey != month) _bad('head_month_mismatch');
      if (includeDeleted || !value.deleted) out.add(value);
    }
    return out;
  }

  /// Discovery is read-only, including months whose blocks were moved/deleted.
  Future<List<String>> monthKeysForTopic(String topicId) async {
    final topic = _identifier(topicId, 'invalid_topic', pattern: _topicPattern);
    final rows = await db.customSelect(
      'SELECT month_key FROM mod_month_pages WHERE topic_id = ?'
      ' ORDER BY month_key DESC',
      variables: [Variable.withString(topic)],
    ).get();
    return rows.map((r) => r.read<String>('month_key')).toList(growable: false);
  }

  /// The summary is stored once, but the view must decide whether to show
  /// it collapsed; it is deliberately not included in entry previews.
  Future<ModStoredBlock?> readSummary({
    required String topicId, required String monthKey,
  }) async {
    final items = await readMonth(topicId: topicId, monthKey: monthKey);
    for (final item in items) {
      if (item.kind == 'summary') return item;
    }
    return null;
  }
}
