// W9.8.3 — checksummed structured graph V2 with durable daily mappings.
// This is NOT a user backup, ZIP, WebDAV, native Diary or media archive.
// Import is permitted only into an isolated EMPTY database in tests.
import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'db/database.dart';
import 'mod_month_graph_archive_v1.dart';

final class ModGraphV2Exception implements Exception {
  final String code;
  const ModGraphV2Exception(this.code);
  @override
  String toString() => 'ModGraphV2Exception($code)';
}

final class _VerifiedV2 {
  final Map<String,dynamic> graph;
  final List<Map<String,Object?>> days;
  final String sha;
  const _VerifiedV2(this.graph,this.days,this.sha);
}

final class ModMonthGraphArchiveV2 {
  const ModMonthGraphArchiveV2._();
  static const format='moodiary-month-day-graph';
  static const version=2;
  static const scope='isolated-structured-only';
  static const _limit=64*1024*1024;
  static const _columns=<String>[
    'topic_id','day_key','diary_id','visible_local','created_ms',
  ];

  static Never _fail(String code)=>throw ModGraphV2Exception(code);
  static String _hash(Object item)=>
      sha256.convert(utf8.encode(jsonEncode(item))).toString();
  static Map<String,Object?> _body(Map<String,dynamic> graph,
    List<Map<String,Object?>> days)=> {
      'format':format,'version':version,'scope':scope,
      'monthGraph':graph,'dayPages':days,
    };

  /// One transaction snapshots revisions, heads, operations and day mappings.
  /// It refuses any linked native Diary: that requires a future full bundle.
  static Future<String> exportGraph(MoodiaryDatabase db) =>
      db.transaction(() async {
    final text=await ModMonthGraphArchiveV1
        .exportMonthPartForDayEnvelopeV2(db);
    final graph=jsonDecode(text) as Map<String,dynamic>;
    final rows=await db.customSelect(
      'SELECT topic_id,day_key,diary_id,visible_local,created_ms '
      'FROM mod_day_pages ORDER BY topic_id ASC,day_key ASC',
    ).get();
    if(rows.length>250000)_fail('too_many_day_pages');
    final days=<Map<String,Object?>>[
      for(final r in rows) {
        'topic_id':r.read<String>('topic_id'),
        'day_key':r.read<String>('day_key'),
        'diary_id':r.readNullable<String>('diary_id'),
        'visible_local':r.read<int>('visible_local'),
        'created_ms':r.read<int>('created_ms'),
      },
    ];
    _validate(graph,days);
    final body=_body(graph,days);
    final encoded=jsonEncode({...body,'sha256':_hash(body)});
    if(utf8.encode(encoded).length>_limit)_fail('too_large');
    return encoded;
  });

  static void verify(String encoded)=>_decode(encoded);

  static bool _day(String day) {
    if(!RegExp(r'^[0-9]{4}-(0[1-9]|1[0-2])-[0-9]{2}$')
      .hasMatch(day))return false;
    final y=int.parse(day.substring(0,4));
    final m=int.parse(day.substring(5,7));
    final d=int.parse(day.substring(8,10));
    if(y<1)return false;
    final date=DateTime.utc(y,m,d);
    return date.year==y && date.month==m && date.day==d;
  }

  static void _validate(Map<String,dynamic> graph,
    List<Map<String,Object?>> days) {
    try {
      ModMonthGraphArchiveV1.verify(jsonEncode(graph));
    } on ModGraphArchiveException {
      _fail('invalid_month_graph');
    }
    final raw=graph['tables'];
    if(raw is! Map<String,dynamic>)_fail('invalid_month_graph');
    final pages=raw['mod_month_pages'] as List<dynamic>;
    final blocks=raw['mod_month_blocks'] as List<dynamic>;
    final revisions=raw['mod_month_revisions'] as List<dynamic>;
    final months=<String>{};
    for(final v in pages) {
      final r=v as Map<String,dynamic>;
      if(r['diary_id']!=null)_fail('native_month_binding_requires_full_archive');
      months.add((r['topic_id'] as String)+'|'+(r['month_key'] as String));
    }
    final topics=<String,String>{}, kinds=<String,String>{};
    for(final v in blocks) {
      final r=v as Map<String,dynamic>, id=r['block_id'] as String;
      topics[id]=r['topic_id'] as String;
      kinds[id]=r['kind'] as String;
    }
    // Tombstones and moved blocks retain their historical day mappings.
    final history=<String>{};
    for(final v in revisions) {
      final r=v as Map<String,dynamic>, id=r['block_id'] as String;
      if(kinds[id]=='entry')history.add(topics[id]!+'|'+(r['day_key'] as String));
    }
    final seen=<String>{};
    String? last;
    for(final row in days) {
      if(row.length!=_columns.length ||
        !row.keys.toSet().containsAll(_columns))_fail('invalid_day_shape');
      final topic=row['topic_id'], day=row['day_key'];
      final visible=row['visible_local'], created=row['created_ms'];
      if(topic is! String ||
          !RegExp(r'^[a-zA-Z0-9_-]{1,120}$').hasMatch(topic) ||
          day is! String || !_day(day))_fail('invalid_day_identity');
      if(row['diary_id']!=null)_fail('native_day_binding_requires_full_archive');
      if(visible is! int || (visible!=0 && visible!=1) ||
          created is! int || created<0)_fail('invalid_day_metadata');
      final key=topic+'|'+day;
      if(!seen.add(key))_fail('duplicate_day_mapping');
      if(last!=null && key.compareTo(last)<=0)_fail('days_not_sorted');
      last=key;
      if(!months.contains(topic+'|'+day.substring(0,7)) ||
         !history.contains(key))_fail('orphan_day_mapping');
    }
  }

  static _VerifiedV2 _decode(String encoded) {
    if(utf8.encode(encoded).length>_limit)_fail('too_large');
    final Object? obj;
    try {obj=jsonDecode(encoded);} catch(_){_fail('invalid_json');}
    if(obj is! Map<String,dynamic> || obj.length!=6 ||
       !obj.keys.toSet().containsAll({
         'format','version','scope','monthGraph','dayPages','sha256',
       }) || obj['format']!=format || obj['version']!=version ||
       obj['scope']!=scope || obj['monthGraph'] is! Map<String,dynamic> ||
       obj['dayPages'] is! List || obj['sha256'] is! String){
      _fail('invalid_header');
    }
    final graph=obj['monthGraph'] as Map<String,dynamic>;
    final raw=obj['dayPages'] as List<dynamic>;
    if(raw.length>250000)_fail('too_many_day_pages');
    final days=<Map<String,Object?>>[];
    for(final v in raw){
      if(v is! Map<String,dynamic>)_fail('invalid_day_shape');
      days.add(Map<String,Object?>.from(v));
    }
    final digest=_hash(_body(graph,days));
    if(digest!=obj['sha256'])_fail('checksum_mismatch');
    _validate(graph,days);
    return _VerifiedV2(graph,days,digest);
  }

  /// Test-only isolated recovery with readback; no live activation.
  /// A single outer transaction rolls back V1 and day rows on ANY failure.
  @visibleForTesting
  static Future<void> restoreIntoIsolatedEmptyDatabaseForTest(
    MoodiaryDatabase db,String encoded) async {
    final item=_decode(encoded);
    await db.transaction(() async {
      final present=await db.customSelect(
        'SELECT COUNT(*) AS n FROM mod_day_pages').getSingle();
      if(present.read<int>('n')!=0)_fail('nonempty_day_target');
      await ModMonthGraphArchiveV1.restoreIntoIsolatedEmptyDatabaseForTest(
        db,jsonEncode(item.graph));
      for(final row in item.days) {
        await db.customStatement(
          'INSERT INTO mod_day_pages '
          '(topic_id,day_key,diary_id,visible_local,created_ms) '
          'VALUES(?,?,?,?,?)',
          [row['topic_id'],row['day_key'],row['diary_id'],
           row['visible_local'],row['created_ms']],
        );
      }
      final readback=_decode(await exportGraph(db));
      if(readback.sha!=item.sha)_fail('readback_mismatch');
    });
  }
}
