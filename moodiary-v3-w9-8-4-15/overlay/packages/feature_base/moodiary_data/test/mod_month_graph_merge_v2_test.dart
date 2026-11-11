import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moodiary_data/moodiary_data.dart';
import 'package:moodiary_data/src/mod_month_graph_archive_v2.dart';
import 'package:moodiary_data/src/mod_month_graph_merge_v2.dart';

const _topic = 'topic0001';
const _block = 'block0001';
const _rootRevision = 'revision0001';
const _day = '2026-11-11';
const _month = '2026-11';

String _doc(String value) => jsonEncode({
  'type':'doc','content':[{'type':'paragraph','content':[
    {'type':'text','text':value},
  ]}],
});
String _hash(Object value) => sha256.convert(utf8.encode(jsonEncode(value))).toString();

Future<void> _putRevision(MoodiaryDatabase db, {
  required String revision,
  required String body,
  required String operation,
  String? parent,
  bool deleted = false,
  int time = 100,
}) async {
  await db.customStatement(
    'INSERT INTO mod_month_revisions '
    '(revision_id,block_id,parent_revision_id,month_key,day_key,'
    'occurred_at_ms,body_json,deleted,edited_at_ms)'
    ' VALUES(?,?,?,?,?,?,?,?,?)',
    [revision,_block,parent,_month,_day,time,body,deleted?1:0,time+10],
  );
  await db.customStatement(
    'INSERT INTO mod_month_ops '
    '(operation_id,payload_sha256,block_id,revision_id,applied_at_ms)'
    ' VALUES(?,?,?,?,?)',
    [operation,_hash([
      _block,revision,_topic,_month,'entry',parent,_day,time,body,deleted,
    ]),_block,revision,time+10],
  );
}

Future<MoodiaryDatabase> _seed({
  required String childRevision,
  required String childBody,
  required String childOperation,
  bool deleted = false,
  int created = 100,
  int visible = 1,
}) async {
  final db = MoodiaryDatabase.forTesting(NativeDatabase.memory(
    setup: (raw) => raw.execute('PRAGMA foreign_keys=ON'),
  ));
  await db.customStatement(
    'INSERT INTO mod_month_pages(topic_id,month_key,diary_id,created_ms)'
    ' VALUES(?,?,NULL,?)',[_topic,_month,created],
  );
  await db.customStatement(
    'INSERT INTO mod_month_blocks(block_id,topic_id,month_key,kind,created_ms)'
    ' VALUES(?,?,?,?,?)',[_block,_topic,_month,'entry',100],
  );
  await _putRevision(db,
    revision:_rootRevision,body:_doc('base'),operation:'operation0001');
  await _putRevision(db,
    revision:childRevision,body:childBody,operation:childOperation,
    parent:_rootRevision,deleted:deleted,time:200);
  await db.customStatement(
    'INSERT INTO mod_month_heads(block_id,revision_id) VALUES(?,?)',
    [_block,childRevision],
  );
  await db.customStatement(
    'INSERT INTO mod_day_pages '
    '(topic_id,day_key,diary_id,visible_local,created_ms)'
    ' VALUES(?,?,NULL,?,?)',[_topic,_day,visible,created],
  );
  return db;
}

void main() {
  test('two offline branches preserve both revision heads, operations, '
      'tombstones and local day visibility', () async {
    final left = await _seed(
      childRevision:'revision0002',childBody:_doc('local edit'),
      childOperation:'operation0002',visible:0,created:120);
    final right = await _seed(
      childRevision:'revision0003',childBody:_doc('remote deletion'),
      childOperation:'operation0003',deleted:true,visible:1,created:110);
    try {
      final local = await ModMonthGraphArchiveV2.exportGraph(left);
      final remote = await ModMonthGraphArchiveV2.exportGraph(right);
      final merged = ModMonthGraphMergeV2.merge(local:local,remote:remote);
      ModMonthGraphArchiveV2.verify(merged);
      final graph = jsonDecode(merged) as Map<String,dynamic>;
      final tables = (graph['monthGraph'] as Map)['tables'] as Map;
      expect((tables['mod_month_revisions'] as List).length,3);
      expect((tables['mod_month_ops'] as List).length,3);
      expect({for(final x in tables['mod_month_heads'] as List)
        (x as Map)['revision_id']}, {'revision0002','revision0003'});
      final deletion = (tables['mod_month_revisions'] as List)
        .cast<Map>().singleWhere((r)=>r['revision_id']=='revision0003');
      expect(deletion['deleted'],1);
      expect((graph['dayPages'] as List).single['visible_local'],0);
      expect((graph['dayPages'] as List).single['created_ms'],110);
      expect((tables['mod_month_pages'] as List).single['created_ms'],110);
      expect(ModMonthGraphMergeV2.merge(local:local,remote:remote),merged,
        reason:'identical inputs must deterministically merge');
      expect(await ModMonthGraphArchiveV2.exportGraph(left),local,
        reason:'merge must not alter source SQLite');
      expect(await ModMonthGraphArchiveV2.exportGraph(right),remote);

      final isolated = MoodiaryDatabase.forTesting(NativeDatabase.memory(
        setup:(raw)=>raw.execute('PRAGMA foreign_keys=ON'),
      ));
      try {
        await isolated.customStatement(
          'INSERT INTO diaries(id,title,content,content_text,time,'
          'last_modified,show,type) VALUES(?,?,?,?,?,?,?,?)',
          [_topic,'native topic',_doc('topic'),'topic',100000,100000,1,'tiptap'],
        );
        await ModMonthGraphArchiveV2.restoreIntoEmptyDatabase(isolated,merged);
        expect(await ModMonthGraphArchiveV2.exportGraph(isolated),merged);
        expect(await isolated.customSelect('PRAGMA foreign_key_check').get(),isEmpty);
      } finally {
        await isolated.close();
      }
    } finally {
      await left.close();
      await right.close();
    }
  });

  test('rejects operation ID reused for different offline edits', () async {
    final left = await _seed(
      childRevision:'revision0002',childBody:_doc('edit A'),
      childOperation:'operation0002');
    final right = await _seed(
      childRevision:'revision0003',childBody:_doc('edit B'),
      childOperation:'operation0002');
    try {
      final local = await ModMonthGraphArchiveV2.exportGraph(left);
      final remote = await ModMonthGraphArchiveV2.exportGraph(right);
      expect(() => ModMonthGraphMergeV2.merge(local:local,remote:remote),
        throwsA(isA<ModMonthGraphMergeException>().having(
          (e)=>e.code,'code','identity_conflict_mod_month_ops')));
    } finally {
      await left.close();
      await right.close();
    }
  });

  test('rejects immutable revision ID collision instead of overwriting', () async {
    final left = await _seed(
      childRevision:'revision0002',childBody:_doc('local content'),
      childOperation:'operation0002');
    final right = await _seed(
      childRevision:'revision0002',childBody:_doc('remote content'),
      childOperation:'operation0003');
    try {
      final local = await ModMonthGraphArchiveV2.exportGraph(left);
      final remote = await ModMonthGraphArchiveV2.exportGraph(right);
      expect(() => ModMonthGraphMergeV2.merge(local:local,remote:remote),
        throwsA(isA<ModMonthGraphMergeException>().having(
          (e)=>e.code,'code','identity_conflict_mod_month_revisions')));
    } finally {
      await left.close();
      await right.close();
    }
  });

  test('rejects corrupted remote graph before any merge', () async {
    final left = await _seed(
      childRevision:'revision0002',childBody:_doc('fine'),
      childOperation:'operation0002');
    try {
      final local = await ModMonthGraphArchiveV2.exportGraph(left);
      final corrupted = local.replaceFirst('revision0002','revision0009');
      expect(() => ModMonthGraphMergeV2.merge(local:local,remote:corrupted),
        throwsA(isA<ModMonthGraphMergeException>().having(
          (e)=>e.code,'code','invalid_source_graph')));
    } finally {
      await left.close();
    }
  });
}
