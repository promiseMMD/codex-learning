// W9.7.7.4: uses the real Flutter test engine, never a plain Dart VM.
// This deliberately cannot access live Moodiary storage.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:drift/native.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moodiary_data/moodiary_data.dart';
import 'package:moodiary_sync/src/data/mod_month_recovery_slot_v2.dart';
import 'package:path/path.dart' as p;

const topicId='aac26e25-4a1d-4b4c-b256-9b0c347d36e2';
const oldId='generation_baseline_2026',newId='generation_incoming_2026';
Never fail(String msg) => throw StateError('SIGKILL_V2_CHILD_FAILURE: '+msg);
void check(bool yes,String msg) {
  if (!yes) fail(msg);
}
Future<String> source(String root,String label,int value) async {
  final dir=p.join(root,'v2-real-sigkill-source-'+label);
  final sqlite=File(p.join(dir,'database','restored.sqlite'));
  final current=File(p.join(dir,'media','image','current.png'));
  await sqlite.parent.create(recursive:true);
  await current.parent.create(recursive:true);
  await current.writeAsBytes([137,80,78,71,value],flush:true);
  await File(p.join(dir,'media','image','historic.png'))
    .writeAsBytes([137,80,78,71,value,42],flush:true);
  final db=MoodiaryDatabase.forTesting(NativeDatabase(sqlite));
  try {
    await db.customSelect('SELECT 1').get();
    final doc=jsonEncode({'type':'doc','attrs':{'v':2},
      'content':[{'type':'paragraph','content':[{'type':'text','text':label}]}]});
    await db.customStatement(
      'INSERT INTO diaries'
      '(id,title,content,content_text,time,last_modified,show,type)'
      ' VALUES(?,?,?,?,?,?,?,?)',
      [topicId,'测试主题 '+label,doc,label,
        1794038400000000,1794038400000000,1,'tiptap']);
    await db.customStatement(
      'INSERT INTO mod_month_pages'
      '(topic_id,month_key,diary_id,created_ms) VALUES(?,?,NULL,?)',
      [topicId,'2026-11',100+value]);
    const blockId='block-v2-crash-0001';
    const revisionId='revision-v2-crash-0001';
    const day='2026-11-07';
    const kind='entry';
    const month='2026-11';
    final time=200+value;
    final rich=jsonEncode({
      'type':'doc','attrs':{'v':2},'content':[
        {'type':'paragraph','content':[{'type':'text','text':label}]},
        {'type':'image','attrs':{'src':'historic.png'}},
      ],
    });
    final payload=[blockId,revisionId,topicId,month,kind,null,day,time,rich,false];
    final payloadSha=sha256.convert(utf8.encode(jsonEncode(payload))).toString();
    await db.customStatement(
      'INSERT INTO mod_month_blocks'
      '(block_id,topic_id,month_key,kind,created_ms) VALUES(?,?,?,?,?)',
      [blockId,topicId,month,kind,100+value]);
    await db.customStatement(
      'INSERT INTO mod_month_revisions'
      '(revision_id,block_id,parent_revision_id,month_key,day_key,'
      'occurred_at_ms,body_json,deleted,edited_at_ms)'
      ' VALUES(?,?,NULL,?,?,?,?,?,?)',
      [revisionId,blockId,month,day,time,rich,0,time+1]);
    await db.customStatement(
      'INSERT INTO mod_month_heads(block_id,revision_id) VALUES(?,?)',
      [blockId,revisionId]);
    await db.customStatement(
      'INSERT INTO mod_month_ops'
      '(operation_id,payload_sha256,block_id,revision_id,applied_at_ms)'
      ' VALUES(?,?,?,?,?)',
      ['operation-v2-crash-0001',payloadSha,blockId,revisionId,time+1]);
    await db.customStatement(
      'INSERT INTO mod_day_pages'
      '(topic_id,day_key,diary_id,visible_local,created_ms)'
      ' VALUES(?,?,NULL,?,?)',
      [topicId,day,value.isOdd?0:1,201+value]);
    check((await ModMonthGraphArchiveV2.exportGraph(db)).contains('2026-11'),
      'source_graph_missing');
  } finally { await db.close(); }
  await File(p.join(dir,'restore-state.json')).writeAsString(jsonEncode({
    'format':'moodiary-v2-isolated-restore','version':2,
    'phase':'ready','liveDataModified':false,
  }),flush:true);
  return dir;
}
void main() {
  test('real Flutter process SIGKILL on private slot', () async {
    final env=Platform.environment;
    final mode=env['MOODIARY_V2_TEST_MODE']??'';
    final sandbox=p.normalize(p.absolute(env['MOODIARY_V2_TEST_SANDBOX']??''));
    final root=p.normalize(p.absolute(env['MOODIARY_V2_TEST_ROOT']??''));
    final signal=p.normalize(p.absolute(env['MOODIARY_V2_TEST_SIGNAL']??''));
    final phase=env['MOODIARY_V2_TEST_PHASE']??'';
    final temp=p.normalize(p.absolute(Directory.systemTemp.path));
    check(p.isWithin(temp,sandbox) &&
      p.basename(sandbox).startsWith('w9843-crash-'), 'unsafe_test_sandbox');
    check(p.dirname(root)==sandbox &&
      p.basename(root).startsWith('v2-real-sigkill-slot-'),'unsafe_slot');
    check(p.dirname(signal)==sandbox &&
      p.basename(signal).startsWith('checkpoint-'),'unsafe_marker');
    check(const ['prepare','install','recover'].contains(mode),'bad_mode');
    print('SIGKILL_V2_CHILD_BOOT='+pid.toString());
    if (mode=='prepare') {
      final previous=await source(sandbox,'baseline',11);
      await source(sandbox,'incoming',12);
      final slot=await ModMonthRecoverySlotV2.createNew(root);
      await slot.installVerified(sourceDirectory:previous,generationId:oldId);
      check((await slot.currentDirectory())?.endsWith(oldId)==true,
        'baseline_missing');
      print('SIGKILL_V2_SETUP_OK');
      return;
    }
    final slot=await ModMonthRecoverySlotV2.openExisting(root);
    if (mode=='recover') {
      final result=await slot.recover();
      final active=await slot.currentDirectory();
      check(active!=null,'active_missing_after_recovery');
      final database=File(p.join(active!,'database','restored.sqlite'));
      final db=MoodiaryDatabase.forTesting(NativeDatabase(database));
      try {
        final rows=await db.customSelect('PRAGMA integrity_check').get();
        check(rows.length==1 &&
          rows.first.read<String>('integrity_check')=='ok',
          'sqlite_integrity_failed');
        final count=await db.customSelect(
          'SELECT COUNT(*) AS n FROM diaries').getSingle();
        check(count.read<int>('n')==1,'diary_row_lost');
        check((await ModMonthGraphArchiveV2.exportGraph(db)).contains('2026-11'),
          'monthly_graph_missing');
        final daily=await db.customSelect(
          'SELECT day_key,visible_local FROM mod_day_pages').getSingle();
        check(daily.read<String>('day_key')=='2026-11-07',
          'daily_identity_lost');
        final expected=p.basename(active)==oldId?0:1;
        check(daily.read<int>('visible_local')==expected,
          'daily_visibility_mismatch');
        final name=await db.customSelect(
          'SELECT title FROM diaries').getSingle();
        check(name.read<String>('title').contains(
          p.basename(active)==oldId?'baseline':'incoming'),
          'native_diary_generation_mismatch');
      } finally { await db.close(); }
      check(await slot.recover()=='clean','recovery_not_idempotent');
      print('SIGKILL_V2_RECOVER='+jsonEncode({
        'result':result,'active':p.basename(active),
      }));
      return;
    }
    await slot.installVerified(
      sourceDirectory:p.join(sandbox,'v2-real-sigkill-source-incoming'),
      generationId:newId,
      checkpoint:(at) async {
        if (at!=phase) return;
        print('SIGKILL_V2_CHILD_CHECKPOINT='+at);
        await File(signal).writeAsString(
          jsonEncode({'phase':at,'pid':pid,'root':root}),flush:true);
        // The parent kills THIS OS process, not a Dart exception injection.
        await Completer<void>().future;
      });
    fail('install_finished_without_SIGKILL');
  });
}
