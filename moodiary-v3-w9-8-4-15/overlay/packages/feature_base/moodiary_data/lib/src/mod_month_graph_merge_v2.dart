// W9 WebDAV preparation: verified, lossless month/day history merge candidate.
//
// This module NEVER writes to a live database or remote store. A merged graph
// is not sufficient for activation until native Diary bindings and historical
// media have also been verified. Unsafe collisions fail closed.
import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'mod_month_graph_archive_v1.dart';
import 'mod_month_graph_archive_v2.dart';

final class ModMonthGraphMergeException implements Exception {
  const ModMonthGraphMergeException(this.code);
  final String code;
  @override
  String toString() => 'ModMonthGraphMergeException($code)';
}

final class ModMonthGraphMergeV2 {
  const ModMonthGraphMergeV2._();

  static Never _fail(String code) => throw ModMonthGraphMergeException(code);
  static String _sha(Object value) =>
      sha256.convert(utf8.encode(jsonEncode(value))).toString();

  static const _keys = <String, List<String>>{
    'mod_month_pages': ['topic_id', 'month_key'],
    'mod_month_blocks': ['block_id'],
    'mod_month_revisions': ['revision_id'],
    'mod_month_ops': ['operation_id'],
  };

  static String _identity(Map<String, dynamic> row, List<String> fields) =>
      jsonEncode([for (final name in fields) row[name]]);

  static bool _same(Map<String, dynamic> a, Map<String, dynamic> b) =>
      a.length == b.length &&
      a.keys.every((key) => b.containsKey(key) && a[key] == b[key]);

  static Map<String, dynamic> _decode(String text) {
    try {
      ModMonthGraphArchiveV2.verify(text);
      return jsonDecode(text) as Map<String, dynamic>;
    } catch (_) {
      _fail('invalid_source_graph');
    }
  }

  static List<Map<String, dynamic>> _rows(Object? value) => [
    for (final row in value as List)
      Map<String, dynamic>.from(row as Map<String, dynamic>),
  ];

  static List<Map<String, dynamic>> _union({
    required String table,
    required List<Map<String, dynamic>> local,
    required List<Map<String, dynamic>> remote,
    required List<String> keys,
  }) {
    final rows = <String, Map<String, dynamic>>{};
    for (final row in local) {
      rows[_identity(row, keys)] = row;
    }
    for (final row in remote) {
      final key = _identity(row, keys);
      final prior = rows[key];
      if (prior == null) {
        rows[key] = row;
        continue;
      }
      if (_same(prior, row)) continue;
      // A topic/month is a shared container. Its creation timestamp can
      // safely converge to the earliest value, but native bindings MUST agree.
      if (table == 'mod_month_pages' &&
          prior['topic_id'] == row['topic_id'] &&
          prior['month_key'] == row['month_key'] &&
          prior['diary_id'] == row['diary_id']) {
        prior['created_ms'] =
            (prior['created_ms'] as int) < (row['created_ms'] as int)
                ? prior['created_ms'] : row['created_ms'];
        continue;
      }
      // Revisions, operations and blocks are immutable identities. In-place
      // changes are never silently treated as a last-writer-wins revision.
      _fail('identity_conflict_$table');
    }
    final ordered = rows.keys.toList()..sort();
    return [for (final key in ordered) rows[key]!];
  }

  static List<Map<String, dynamic>> _dayUnion(
    List<Map<String, dynamic>> local, List<Map<String, dynamic>> remote,
  ) {
    final days = <String, Map<String, dynamic>>{};
    String key(Map<String, dynamic> row) =>
        _identity(row, const ['topic_id', 'day_key']);
    for (final row in local) days[key(row)] = row;
    for (final row in remote) {
      final id = key(row), prior = days[id];
      if (prior == null) {
        // This flag is explicitly local to each device. Do not import the
        // remote device's hidden preference when discovering a new day.
        days[id] = {...row, 'visible_local': 1};
      } else {
        if (prior['diary_id'] != row['diary_id']) {
          _fail('day_native_binding_conflict');
        }
        prior['created_ms'] =
            (prior['created_ms'] as int) < (row['created_ms'] as int)
                ? prior['created_ms'] : row['created_ms'];
        // Keep prior.visible_local: it is a device-local preference.
      }
    }
    final ordered = days.keys.toList()..sort();
    return [for (final id in ordered) days[id]!];
  }

  static List<Map<String, dynamic>> _leafHeads(
    List<Map<String, dynamic>> revisions,
  ) {
    final parentIds = <String>{
      for (final row in revisions)
        if (row['parent_revision_id'] is String)
          row['parent_revision_id'] as String,
    };
    final heads = <Map<String, dynamic>>[
      for (final row in revisions)
        if (!parentIds.contains(row['revision_id']))
          {'block_id': row['block_id'], 'revision_id': row['revision_id']},
    ];
    heads.sort((a,b) {
      final block = (a['block_id'] as String).compareTo(b['block_id'] as String);
      return block != 0 ? block :
          (a['revision_id'] as String).compareTo(b['revision_id'] as String);
    });
    return heads;
  }

  /// Produce a verified, deterministic candidate containing the UNION of
  /// immutable histories. Divergent edit heads remain separate (multi-head).
  ///
  /// No remote fetch, native Diary write, or live DB replacement occurs here.
  /// On any incompatible identity or unique-summary collision the caller
  /// must retain both original graphs and surface a conflict to the user.
  static String merge({required String local, required String remote}) {
    final a = _decode(local), b = _decode(remote);
    if (a['sha256'] == b['sha256']) return local;
    final at = Map<String, dynamic>.from(
      (a['monthGraph'] as Map<String, dynamic>)['tables'] as Map);
    final bt = Map<String, dynamic>.from(
      (b['monthGraph'] as Map<String, dynamic>)['tables'] as Map);

    final tables = <String, List<Map<String, dynamic>>>{};
    for (final entry in _keys.entries) {
      tables[entry.key] = _union(
        table: entry.key,
        local: _rows(at[entry.key]),
        remote: _rows(bt[entry.key]),
        keys: entry.value,
      );
    }
    tables['mod_month_heads'] =
        _leafHeads(tables['mod_month_revisions']!);
    // Preserve the exact V1 canonical table insertion order.
    final canonical = <String, List<Map<String, dynamic>>>{
      'mod_month_pages': tables['mod_month_pages']!,
      'mod_month_blocks': tables['mod_month_blocks']!,
      'mod_month_revisions': tables['mod_month_revisions']!,
      'mod_month_heads': tables['mod_month_heads']!,
      'mod_month_ops': tables['mod_month_ops']!,
    };
    final v1Body = <String, Object?>{
      'format': ModMonthGraphArchiveV1.format,
      'version': ModMonthGraphArchiveV1.version,
      'tables': canonical,
    };
    final inner = {...v1Body, 'sha256': _sha(v1Body)};
    final days = _dayUnion(_rows(a['dayPages']), _rows(b['dayPages']));
    final v2Body = <String, Object?>{
      'format': ModMonthGraphArchiveV2.format,
      'version': ModMonthGraphArchiveV2.version,
      'scope': ModMonthGraphArchiveV2.scope,
      'monthGraph': inner,
      'dayPages': days,
    };
    final candidate = jsonEncode({...v2Body,'sha256': _sha(v2Body)});
    try {
      ModMonthGraphArchiveV2.verify(candidate);
    } catch (_) {
      _fail('merged_graph_invariant_failure');
    }
    return candidate;
  }
}
