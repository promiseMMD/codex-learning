import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:drift/drift.dart' show Variable;
import 'package:crypto/crypto.dart';
import 'package:moodiary_sync/src/data/mod_month_recovery_slot_v1.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moodiary_data/moodiary_data.dart';
import 'package:moodiary_sync/src/data/mod_month_recovery_slot_v2.dart';
import 'package:moodiary_sync/src/data/mod_month_verified_manifest_v1.dart';

const topicId='aac26e25-4a1d-4b4c-b256-9b0c347d36e2';

void main() {
  late Directory scratch;
  setUp(() async {
    scratch=await Directory.systemTemp.createTemp('w9843-slot-');
  });
  tearDown(() async {
    if (await scratch.exists()) await scratch.delete(recursive:true);
  });

  Future<String> source(String label,{int marker=1}) async {
    final root=Directory(scratch.path+'/input-'+label);
    final database=File(root.path+'/database/restored.sqlite');
    final media=File(root.path+'/media/image/photo.png');
    await database.parent.create(recursive:true);
    await media.parent.create(recursive:true);
    await media.writeAsBytes([137,80,78,71,marker],flush:true);
    final db=MoodiaryDatabase.forTesting(NativeDatabase(database));
    try {
      await db.customSelect('SELECT 1').get();
      final body=jsonEncode({'type':'doc','attrs':{'v':2},'content':[
        {'type':'paragraph','content':[{'type':'text','text':label}]}]});
      await db.customStatement(
        'INSERT INTO diaries'
        '(id,title,content,content_text,time,last_modified,show,type)'
        ' VALUES(?,?,?,?,?,?,?,?)',
        [topicId,'主题 '+label,body,label,
          1794038400000000,1794038400000000,1,'tiptap']);
      await db.customStatement(
        'INSERT INTO mod_month_pages'
        '(topic_id,month_key,diary_id,created_ms) VALUES(?,?,NULL,?)',
        [topicId,'2026-11',marker+100]);
      const blockId='block-v2-slot-0001';
      const revisionId='revision-v2-slot-0001';
      const day='2026-11-07';
      const kind='entry';
      const month='2026-11';
      final time=200+marker;
      final operationPayload=[blockId,revisionId,topicId,month,kind,
          null,day,time,body,false];
      final operationSha=sha256.convert(
          utf8.encode(jsonEncode(operationPayload))).toString();
      await db.customStatement(
        'INSERT INTO mod_month_blocks'
        '(block_id,topic_id,month_key,kind,created_ms) VALUES(?,?,?,?,?)',
        [blockId,topicId,month,kind,190+marker]);
      await db.customStatement(
        'INSERT INTO mod_month_revisions'
        '(revision_id,block_id,parent_revision_id,month_key,day_key,'
        'occurred_at_ms,body_json,deleted,edited_at_ms)'
        ' VALUES(?,?,NULL,?,?,?,?,?,?)',
        [revisionId,blockId,month,day,time,body,0,time+1]);
      await db.customStatement(
        'INSERT INTO mod_month_heads(block_id,revision_id) VALUES(?,?)',
        [blockId,revisionId]);
      await db.customStatement(
        'INSERT INTO mod_month_ops'
        '(operation_id,payload_sha256,block_id,revision_id,applied_at_ms)'
        ' VALUES(?,?,?,?,?)',
        ['operation-v2-slot-0001',operationSha,blockId,revisionId,time+1]);
      await db.customStatement(
        'INSERT INTO mod_day_pages'
        '(topic_id,day_key,diary_id,visible_local,created_ms)'
        ' VALUES(?,?,NULL,?,?)',
        [topicId,day,marker.isOdd?0:1,201+marker]);
      expect((await ModMonthGraphArchiveV2.exportGraph(db)).isNotEmpty,true);
    } finally {
      await db.close();
    }
    await File(root.path+'/restore-state.json').writeAsString(jsonEncode({
      'format':'moodiary-v2-isolated-restore','version':2,
      'phase':'ready','liveDataModified':false,
    }),flush:true);
    return root.path;
  }

  Future<ModMonthRecoverySlotV2> makeSlot(String label) =>
    ModMonthRecoverySlotV2.createNew(scratch.path+'/slot-'+label);

  test('strict slot ownership refuses an existing app data directory',
      () async {
    final existing=Directory(scratch.path+'/live-app');
    await existing.create();
    final original=File(existing.path+'/diary.sqlite');
    await original.writeAsString('KEEP');
    await expectLater(ModMonthRecoverySlotV2.createNew(existing.path),
      throwsA(isA<ModBundleInvalid>().having(
        (e)=>e.code,'code','slot_destination_exists')));
    await expectLater(ModMonthRecoverySlotV2.openExisting(existing.path),
      throwsA(isA<ModBundleInvalid>()));
    expect(await original.readAsString(),'KEEP');
  });

  test('SQLite and media are selected together by one verified pointer',
      () async {
    final ready=await source('first');
    final slot=await makeSlot('basic');
    expect(await slot.currentDirectory(),isNull);
    await slot.installVerified(
      sourceDirectory:ready,generationId:'generation_first_2026');
    final reopened=await ModMonthRecoverySlotV2.openExisting(
      scratch.path+'/slot-basic');
    expect(await reopened.recover(),'clean');
    final active=await reopened.currentDirectory();
    expect(active,contains('generation_first_2026'));
    expect(await File(active!+'/media/image/photo.png').readAsBytes(),
      [137,80,78,71,1]);
    final db=MoodiaryDatabase.forTesting(NativeDatabase(
      File(active+'/database/restored.sqlite')));
    try {
      await db.customSelect('SELECT 1').get();
      final n=await db.customSelect('SELECT COUNT(*) AS n FROM diaries')
        .getSingle();
      expect(n.read<int>('n'),1);
      expect(await ModMonthGraphArchiveV2.exportGraph(db),contains('2026-11'));
      final daily=await db.customSelect(
        'SELECT visible_local FROM mod_day_pages WHERE topic_id=?'
        ' AND day_key=?',[Variable.withString(topicId),
                        Variable.withString('2026-11-07')]).getSingle();
      expect(daily.read<int>('visible_local'),0);
    } finally { await db.close(); }
    expect(await File(ready+'/database/restored.sqlite').exists(),true);
  });

  test('old generation is retained even after newer generation activation',
      () async {
    final first=await source('alpha',marker:2);
    final second=await source('beta',marker:3);
    final slot=await makeSlot('history');
    await slot.installVerified(
      sourceDirectory:first,generationId:'generation_first_2026');
    final old=await slot.currentDirectory();
    await slot.installVerified(
      sourceDirectory:second,generationId:'generation_second_2026');
    final active=await slot.currentDirectory();
    expect(active,contains('generation_second_2026'));
    expect(active,isNot(old));
    expect(await File(old!+'/media/image/photo.png').readAsBytes(),
      [137,80,78,71,2]);
    expect(await File(active!+'/media/image/photo.png').readAsBytes(),
      [137,80,78,71,3]);
    expect(await slot.recover(),'clean');
  });

  test('reopen and recover at seven simulated process-death boundaries',
      () async {
    final oldSource=await source('previous',marker:4);
    final newSource=await source('replacement',marker:5);
    const phases=[
      'journal_written','files_copied','generation_verified',
      'directory_moved','generation_installed',
      'pointer_written','journal_committed',
    ];
    for (var i=0;i<phases.length;i++) {
      final phase=phases[i];
      final base=scratch.path+'/slot-break-'+i.toString();
      final slot=await ModMonthRecoverySlotV2.createNew(base);
      await slot.installVerified(
        sourceDirectory:oldSource,generationId:'generation_first_2026');
      final before=await slot.currentDirectory();
      await expectLater(slot.installVerified(
        sourceDirectory:newSource,generationId:'generation_second_2026',
        checkpoint:(value) async {
          if (value==phase) throw ModSlotV2SimulatedProcessDeath(phase);
        }),
        throwsA(isA<ModSlotV2SimulatedProcessDeath>()));
      final fresh=await ModMonthRecoverySlotV2.openExisting(base);
      await expectLater(fresh.currentDirectory(),
        throwsA(isA<ModBundleInvalid>().having(
          (e)=>e.code,'code','restart_recovery_required')));
      final committed=i>=5;
      expect(await fresh.recover(),committed?'committed':'rolled_back');
      final selected=await fresh.currentDirectory();
      expect(selected,committed?contains('generation_second_2026'):before,
        reason:'at phase '+phase);
      expect(await File(before!+'/media/image/photo.png').readAsBytes(),
        [137,80,78,71,4],reason:'old generation must survive '+phase);
      expect(await fresh.recover(),'clean');
      expect(await Directory(
        base+'/generations/.incoming-generation_second_2026').exists(),false);
    }
  });

  test('first-install interrupted before pointer yields no active selection',
      () async {
    final ready=await source('new',marker:6);
    final slot=await makeSlot('first-interrupt');
    await expectLater(slot.installVerified(
      sourceDirectory:ready,generationId:'generation_first_2026',
      checkpoint:(phase) async {
        if (phase=='directory_moved') {
          throw const ModSlotV2SimulatedProcessDeath('directory_moved');
        }
      }),
      throwsA(isA<ModSlotV2SimulatedProcessDeath>()));
    final fresh=await ModMonthRecoverySlotV2.openExisting(
      scratch.path+'/slot-first-interrupt');
    expect(await fresh.recover(),'rolled_back');
    expect(await fresh.currentDirectory(),isNull);
    expect(await File(ready+'/media/image/photo.png').exists(),true);
  });

  test('corrupt new generation after pointer commit rolls back to old',
      () async {
    final oldSource=await source('safe',marker:7);
    final nextSource=await source('new',marker:8);
    final slot=await makeSlot('invalid-new');
    await slot.installVerified(
      sourceDirectory:oldSource,generationId:'generation_first_2026');
    final old=await slot.currentDirectory();
    await expectLater(slot.installVerified(
      sourceDirectory:nextSource,generationId:'generation_second_2026',
      checkpoint:(phase) async {
        if (phase=='pointer_written') {
          throw const ModSlotV2SimulatedProcessDeath('pointer_written');
        }
      }),
      throwsA(isA<ModSlotV2SimulatedProcessDeath>()));
    final changed=File(scratch.path+'/slot-invalid-new/generations/'
      'generation_second_2026/media/image/photo.png');
    await changed.writeAsBytes([0,0,0],flush:true);
    final fresh=await ModMonthRecoverySlotV2.openExisting(
      scratch.path+'/slot-invalid-new');
    expect(await fresh.recover(),'rolled_back_invalid_new');
    expect(await fresh.currentDirectory(),old);
    expect(await File(old!+'/media/image/photo.png').readAsBytes(),
      [137,80,78,71,7]);
    expect(await changed.readAsBytes(),[0,0,0],
      reason:'retain invalid generation as evidence');
  });

  test('post-commit corruption invalidates active generation proof',() async {
    final ready=await source('tamper',marker:9);
    final slot=await makeSlot('tamper');
    await slot.installVerified(
      sourceDirectory:ready,generationId:'generation_first_2026');
    final directory=await slot.currentDirectory();
    await File(directory!+'/media/image/photo.png')
      .writeAsBytes([9,9,9],flush:true);
    await expectLater(slot.currentDirectory(),
      throwsA(isA<ModBundleInvalid>().having(
        (e)=>e.code,'code','generation_files_changed')));
    expect(await File(ready+'/media/image/photo.png').readAsBytes(),
      [137,80,78,71,9]);
  });

  test('forged journal traversal and bad IDs fail closed',() async {
    final slot=await makeSlot('bad-journal');
    final forged=File(scratch.path+'/slot-bad-journal/recovery-journal.json');
    await forged.writeAsString(jsonEncode({
      'format':'moodiary-v2-isolated-generation-slot','version':2,
      'previous':null,'next':'../../escape','phase':'copying',
    }),flush:true);
    await expectLater(slot.recover(),
      throwsA(isA<ModBundleInvalid>().having(
        (e)=>e.code,'code','invalid_restore_journal')));
    expect(await Directory(scratch.path+'/escape').exists(),false);
  });

  test('invalid ID and slot-internal source are blocked',() async {
    final ready=await source('paths');
    final slot=await makeSlot('paths');
    await expectLater(slot.installVerified(
      sourceDirectory:ready,generationId:'../../overwrite'),
      throwsA(isA<ModBundleInvalid>().having(
        (e)=>e.code,'code','invalid_generation_id')));
    await expectLater(slot.installVerified(
      sourceDirectory:scratch.path+'/slot-paths/generations',
      generationId:'generation_safe_2026'),
      throwsA(isA<ModBundleInvalid>().having(
        (e)=>e.code,'code','slot_source_must_be_external')));
  });

  test('external symlink never gets followed or staged',() async {
    final ready=await source('symlink');
    final outside=File(scratch.path+'/secret.txt');
    await outside.writeAsString('KEEP');
    final link=Link(ready+'/media/image/link.png');
    await link.create(outside.path);
    final slot=await makeSlot('symlink');
    await expectLater(slot.installVerified(
      sourceDirectory:ready,generationId:'generation_first_2026'),
      throwsA(isA<ModBundleInvalid>().having(
        (e)=>e.code,'code','unsafe_restore_symlink')));
    expect(await slot.currentDirectory(),isNull);
    expect(await outside.readAsString(),'KEEP');
  });
  test('V2 root cannot masquerade as legacy V1 and V1 sources are rejected',() async {
    final ready=await source('v2-exclusive',marker:11);
    final slot=await makeSlot('v2-root');
    await expectLater(ModMonthRecoverySlotV1.openExisting(
      scratch.path+'/slot-v2-root'),throwsA(isA<ModBundleInvalid>()));
    final v1=Directory(scratch.path+'/legacy-source');
    await v1.create(recursive:true);
    await File(v1.path+'/restore-state.json').writeAsString(jsonEncode({
      'format':'moodiary-isolated-restore','version':1,
      'phase':'ready','liveDataModified':false,
    }),flush:true);
    await expectLater(slot.installVerified(
      sourceDirectory:v1.path,generationId:'generation_v1_2026'),
      throwsA(isA<ModBundleInvalid>().having(
        (e)=>e.code,'code','restore_not_ready')));
    expect(await slot.currentDirectory(),isNull);
    expect(await File(ready+'/restore-state.json').exists(),true);
    await slot.installVerified(
      sourceDirectory:ready,generationId:'generation_v2_2026');
    expect(await slot.currentDirectory(),contains('generation_v2_2026'));
  });

  test('tampering restored day hidden state after pointer commit rolls back',() async {
    final first=await source('old-hidden',marker:13);
    final second=await source('new-visible',marker:14);
    final slot=await makeSlot('bad-day');
    await slot.installVerified(
      sourceDirectory:first,generationId:'generation_first_2026');
    final old=await slot.currentDirectory();
    await expectLater(slot.installVerified(
      sourceDirectory:second,generationId:'generation_second_2026',
      checkpoint:(at) async {
        if (at=='pointer_written') {
          throw const ModSlotV2SimulatedProcessDeath('pointer_written');
        }
      }),
      throwsA(isA<ModSlotV2SimulatedProcessDeath>()));
    final incoming=File(scratch.path+'/slot-bad-day/generations/'
      'generation_second_2026/database/restored.sqlite');
    final db=MoodiaryDatabase.forTesting(NativeDatabase(incoming));
    try {
      await db.customSelect('SELECT 1').get();
      await db.customStatement(
        'UPDATE mod_day_pages SET visible_local=0 WHERE topic_id=?',
        [topicId]);
      final read=await db.customSelect(
        'SELECT visible_local FROM mod_day_pages').getSingle();
      expect(read.read<int>('visible_local'),0);
    } finally {await db.close();}
    final fresh=await ModMonthRecoverySlotV2.openExisting(
      scratch.path+'/slot-bad-day');
    expect(await fresh.recover(),'rolled_back_invalid_new');
    expect(await fresh.currentDirectory(),old);
    final oldDb=MoodiaryDatabase.forTesting(NativeDatabase(
      File(old!+'/database/restored.sqlite')));
    try {
      await oldDb.customSelect('SELECT 1').get();
      expect((await oldDb.customSelect(
        'SELECT visible_local FROM mod_day_pages').getSingle())
        .read<int>('visible_local'),0);
    } finally {await oldDb.close();}
    expect(await File(first+'/database/restored.sqlite').exists(),true);
  });

  test('post-commit hidden-state tamper invalidates current verified proof',() async {
    final ready=await source('committed',marker:16);
    final slot=await makeSlot('post-commit-day');
    await slot.installVerified(
      sourceDirectory:ready,generationId:'generation_first_2026');
    final selected=await slot.currentDirectory();
    final db=MoodiaryDatabase.forTesting(NativeDatabase(
      File(selected!+'/database/restored.sqlite')));
    try {
      await db.customSelect('SELECT 1').get();
      await db.customStatement('UPDATE mod_day_pages SET visible_local=0');
    } finally {await db.close();}
    await expectLater(slot.currentDirectory(),
      throwsA(isA<ModBundleInvalid>().having(
        (e)=>e.code,'code','generation_graph_changed')));
  });

  test('V1 slot can never open a V2-owned root or change its active pointer',() async {
    final ready=await source('keep',marker:17);
    final slot=await makeSlot('version-isolated');
    await slot.installVerified(
      sourceDirectory:ready,generationId:'generation_safe_2026');
    final before=await File(
      scratch.path+'/slot-version-isolated/active.json').readAsBytes();
    await expectLater(ModMonthRecoverySlotV1.openExisting(
      scratch.path+'/slot-version-isolated'),
      throwsA(isA<ModBundleInvalid>()));
    expect(await File(scratch.path+'/slot-version-isolated/active.json')
      .readAsBytes(),orderedEquals(before));
    expect(await slot.recover(),'clean');
  });

}
