// W9.7.1: deterministic, SHA-256 verified local W9 graph archive.
// Deliberately NOT integrated into ZIP, WebDAV or real device restore.
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;

import 'db/database.dart';

final class ModGraphArchiveException implements Exception {
  final String code;
  const ModGraphArchiveException(this.code);
  @override
  String toString() => 'ModGraphArchiveException($code)';
}

final class _GraphTable {
  final String name;
  final List<String> columns;
  final String order;
  const _GraphTable(this.name, this.columns, this.order);
}

final class ModMonthGraphArchiveV1 {
  const ModMonthGraphArchiveV1._();
  static const format = 'moodiary-month-graph';
  static const version = 1;

  static const _tables = <_GraphTable>[
    _GraphTable('mod_month_pages',
      ['topic_id','month_key','diary_id','created_ms'],'topic_id,month_key'),
    _GraphTable('mod_month_blocks',
      ['block_id','topic_id','month_key','kind','created_ms'],'block_id'),
    _GraphTable('mod_month_revisions',
      ['revision_id','block_id','parent_revision_id','month_key','day_key',
        'occurred_at_ms','body_json','deleted','edited_at_ms'],'revision_id'),
    _GraphTable('mod_month_heads',
      ['block_id','revision_id'],'block_id,revision_id'),
    _GraphTable('mod_month_ops',
      ['operation_id','payload_sha256','block_id','revision_id','applied_at_ms'],
      'operation_id'),
  ];
  static const _nullable = <String>{'diary_id','parent_revision_id','day_key'};
  static const _numeric = <String>{
    'created_ms','occurred_at_ms','deleted','edited_at_ms','applied_at_ms'
  };

  static Never _fail(String code) => throw ModGraphArchiveException(code);

  static Future<void> _schema(MoodiaryDatabase db) async {
    final rows = await db.customSelect(
      "SELECT name FROM sqlite_master WHERE type='table' "
      "AND name LIKE 'mod_month_%'",
    ).get();
    final found = rows.map((r) => r.read<String>('name')).toSet();
    if (found.length != _tables.length ||
        !found.containsAll(_tables.map((s) => s.name))) {
      _fail('schema_not_exact');
    }
  }

  static Future<Map<String,List<Map<String,Object?>>>> _snapshot(
    MoodiaryDatabase db,
  ) async {
    await _schema(db);
    final out = <String,List<Map<String,Object?>>>{};
    for (final s in _tables) {
      final rows = await db.customSelect(
        'SELECT ' + s.columns.join(',') + ' FROM ' + s.name +
            ' ORDER BY ' + s.order,
      ).get();
      out[s.name] = [
        for (final r in rows)
          {for (final c in s.columns) c: r.readNullable<Object>(c)}
      ];
    }
    return out;
  }

  static Map<String,Object?> _payload(
    Map<String,List<Map<String,Object?>>> tables,
  ) => {'format':format,'version':version,'tables':tables};

  static String _sha(Object v) =>
      sha256.convert(utf8.encode(jsonEncode(v))).toString();

  /// Copies W9 metadata, all revisions, tombstones, heads and operation IDs.
  /// It does NOT include the ordinary Topic Diary or binary media attachments.
  static Future<String> exportGraph(MoodiaryDatabase db) =>
      db.transaction(() async {
        final tables = await _snapshot(db);
        _validate(tables);
        final body = _payload(tables);
        return jsonEncode({...body,'sha256':_sha(body)});
      });

  /// Verification does not touch SQLite or modify the supplied source.
  static void verify(String encoded) {
    _decode(encoded);
  }

  static Map<String,List<Map<String,Object?>>> _decode(String encoded) {
    if (encoded.length > 64 * 1024 * 1024) _fail('too_large');
    final Object? decoded;
    try {
      decoded = jsonDecode(encoded);
    } catch (_) {
      _fail('invalid_json');
    }
    if (decoded is! Map<String,dynamic> ||
        decoded.length != 4 ||
        !decoded.keys.toSet().containsAll({'format','version','tables','sha256'}) ||
        decoded['format'] != format || decoded['version'] != version ||
        decoded['sha256'] is! String ||
        decoded['tables'] is! Map<String,dynamic>) {
      _fail('invalid_header');
    }
    final rawTables = decoded['tables'] as Map<String,dynamic>;
    if (rawTables.length != _tables.length ||
        !rawTables.keys.toSet().containsAll(_tables.map((s)=>s.name))) {
      _fail('unexpected_tables');
    }

    final tables = <String,List<Map<String,Object?>>>{};
    for (final s in _tables) {
      final items = rawTables[s.name];
      if (items is! List || items.length > 250000) _fail('row_limit');
      final rows = <Map<String,Object?>>[];
      for (final item in items) {
        if (item is! Map<String,dynamic> ||
            item.length != s.columns.length ||
            !item.keys.toSet().containsAll(s.columns)) {
          _fail('invalid_row_shape');
        }
        final row = <String,Object?>{};
        for (final c in s.columns) {
          final v = item[c];
          if (v == null && _nullable.contains(c)) {
            row[c] = null;
          } else if (_numeric.contains(c)) {
            if (v is! int || v < 0 ||
                (c == 'deleted' && v != 0 && v != 1)) {
              _fail('invalid_number');
            }
            row[c] = v;
          } else if (v is String &&
              v.length <= (c == 'body_json' ? 2 * 1024 * 1024 : 1024 * 1024)) {
            row[c] = v;
          } else {
            _fail('invalid_text');
          }
        }
        rows.add(row);
      }
      tables[s.name] = rows;
    }
    if (_sha(_payload(tables)) != decoded['sha256']) {
      _fail('checksum_mismatch');
    }
    _validate(tables);
    return tables;
  }

  static bool _id(String s,{bool topic = false}) =>
      RegExp(topic
        ? r'^[a-zA-Z0-9_-]{1,120}$' : r'^[a-zA-Z0-9_-]{8,120}$')
          .hasMatch(s);
  static bool _month(String s) =>
      RegExp(r'^[0-9]{4}-(0[1-9]|1[0-2])$').hasMatch(s) &&
      int.parse(s.substring(0,4)) > 0;
  static bool _day(String day,String month) {
    if (!RegExp(r'^[0-9]{4}-[0-9]{2}-[0-9]{2}$').hasMatch(day) ||
        !day.startsWith('$month-')) return false;
    final y=int.parse(day.substring(0,4)), m=int.parse(day.substring(5,7));
    final d=int.parse(day.substring(8,10));
    final dt=DateTime.utc(y,m,d);
    return dt.year==y && dt.month==m && dt.day==d;
  }
  static String _key(String topic,String month) => '$topic|$month';

  static void _validate(Map<String,List<Map<String,Object?>>> t) {
    final pages=<String,Map<String,Object?>>{};
    final diaryBindings=<String>{};
    for (final row in t['mod_month_pages']!) {
      final topic=row['topic_id'] as String, month=row['month_key'] as String;
      final diary=row['diary_id'] as String?;
      final key=_key(topic,month);
      if (!_id(topic,topic:true) || !_month(month) || pages.containsKey(key) ||
          (diary != null && (!_id(diary) || !diaryBindings.add(diary)))) {
        _fail('bad_month_mapping');
      }
      pages[key]=row;
    }
    final blocks=<String,Map<String,Object?>>{};
    final summaries=<String>{};
    for (final row in t['mod_month_blocks']!) {
      final id=row['block_id'] as String, topic=row['topic_id'] as String;
      final month=row['month_key'] as String, kind=row['kind'] as String;
      if (!_id(id) || !_id(topic,topic:true) || !_month(month) ||
          !pages.containsKey(_key(topic,month)) ||
          (kind!='entry' && kind!='summary') || blocks.containsKey(id)) {
        _fail('bad_block_mapping');
      }
      if (kind=='summary' && !summaries.add(_key(topic,month))) {
        _fail('duplicate_summary');
      }
      blocks[id]=row;
    }
    final revisions=<String,Map<String,Object?>>{};
    final byBlock=<String,Set<String>>{};
    final parented=<String>{};
    for (final row in t['mod_month_revisions']!) {
      final id=row['revision_id'] as String, blockId=row['block_id'] as String;
      final block=blocks[blockId], month=row['month_key'] as String;
      final day=row['day_key'] as String?;
      if (!_id(id) || revisions.containsKey(id) || block==null ||
          !_month(month) ||
          (block['kind']=='entry'
           ? (day==null || !_day(day,month))
           : (day!=null || month!=block['month_key']))) {
        _fail('bad_revision');
      }
      try {
        final doc=jsonDecode(row['body_json'] as String);
        if (doc is! Map || doc['type']!='doc') _fail('bad_tiptap_body');
      } on ModGraphArchiveException {
        rethrow;
      } catch (_) {
        _fail('bad_tiptap_body');
      }
      revisions[id]=row;
      byBlock.putIfAbsent(blockId,()=> <String>{}).add(id);
    }
    for (final row in revisions.values) {
      final id=row['revision_id'] as String;
      final parent=row['parent_revision_id'] as String?;
      if (parent!=null) {
        if (parent==id || revisions[parent]?['block_id']!=row['block_id']) {
          _fail('bad_parent');
        }
        parented.add(parent);
      }
    }
    // Linear-time cycle detection, including very long revision chains.
    final visited=<String,int>{};
    for (final id in revisions.keys) {
      final trail=<String>[];
      String? at=id;
      while (at!=null && visited[at]!=2) {
        if (visited[at]==1) _fail('revision_cycle');
        visited[at]=1;
        trail.add(at);
        at=revisions[at]?['parent_revision_id'] as String?;
      }
      for (final node in trail) {
        visited[node]=2;
      }
    }
    final heads=<String,Set<String>>{};
    for (final h in t['mod_month_heads']!) {
      final block=h['block_id'] as String, rev=h['revision_id'] as String;
      if (revisions[rev]?['block_id']!=block ||
          !heads.putIfAbsent(block,()=> <String>{}).add(rev)) {
        _fail('bad_head');
      }
    }
    for (final block in blocks.keys) {
      final expected=(byBlock[block] ?? <String>{}).difference(parented);
      final actual=heads[block] ?? <String>{};
      if (expected.isEmpty || actual.length!=expected.length ||
          !actual.containsAll(expected)) _fail('invalid_heads');
    }
    final operations=<String>{};
    for (final op in t['mod_month_ops']!) {
      final id=op['operation_id'] as String;
      final blockId=op['block_id'] as String;
      final revisionId=op['revision_id'] as String;
      final r=revisions[revisionId], b=blocks[blockId];
      if (!_id(id) || !operations.add(id) || r==null || b==null ||
          r['block_id']!=blockId) _fail('invalid_operation');
      final fingerprint=_sha([
        blockId,revisionId,b['topic_id'],r['month_key'],b['kind'],
        r['parent_revision_id'],r['day_key'],r['occurred_at_ms'],
        r['body_json'],r['deleted']==1,
      ]);
      if (fingerprint!=op['payload_sha256']) _fail('bad_operation_hash');
    }
  }

  /// Test-only restore into an isolated, empty database. This is not a user
  /// restore API: it refuses databases with ordinary Diaries or W9 records.
  /// No application code calls it, and no real ZIP/WebDAV guard is lifted.
  @visibleForTesting
  static Future<void> restoreIntoIsolatedEmptyDatabaseForTest(
    MoodiaryDatabase db, String encoded,
  ) async {
    final graph=_decode(encoded);
    await db.transaction(() async {
      await _schema(db);
      for (final s in _tables) {
        final count=await db.customSelect(
          'SELECT COUNT(*) AS n FROM ' + s.name,
        ).getSingle();
        if (count.read<int>('n')!=0) _fail('nonempty_target');
      }
      final diaryCount=await db.customSelect(
        'SELECT COUNT(*) AS n FROM diaries',
      ).getSingle();
      if (diaryCount.read<int>('n')!=0) _fail('native_diaries_present');
      // Insert parent revisions before children. UUID lexical order is
      // unrelated to ancestry; SQLite foreign keys can be enabled on restore.
      final originals=graph['mod_month_revisions']!;
      final byRevision={
        for (final r in originals) r['revision_id'] as String:r
      };
      final descendants=<String,List<String>>{};
      final ready=<String>[];
      for (final r in originals) {
        final id=r['revision_id'] as String;
        final parent=r['parent_revision_id'] as String?;
        if (parent==null) {
          ready.add(id);
        } else {
          descendants.putIfAbsent(parent,()=> <String>[]).add(id);
        }
      }
      ready.sort();
      final parentFirst=<Map<String,Object?>>[];
      for (var i=0;i<ready.length;i++) {
        final id=ready[i];
        parentFirst.add(byRevision[id]!);
        final children=descendants[id] ?? <String>[];
        children.sort();
        ready.addAll(children);
      }
      if (parentFirst.length!=originals.length) _fail('invalid_dag_order');
      for (final s in _tables) {
        final marks=List.filled(s.columns.length,'?').join(',');
        final rows=s.name=='mod_month_revisions'
            ? parentFirst : graph[s.name]!;
        for (final row in rows) {
          await db.customStatement(
            'INSERT INTO ' + s.name + ' (' + s.columns.join(',') +
                ') VALUES (' + marks + ')',
            [for (final c in s.columns) row[c]],
          );
        }
      }
      final restored=await _snapshot(db);
      _validate(restored);
      if (_sha(_payload(restored))!=_sha(_payload(graph))) {
        _fail('readback_mismatch');
      }
    });
  }
}
