// W9.7.7.2: REAL Linux SIGKILL test outside flutter test.
//
// Running child Dart processes from inside flutter test can block on SDK
// startup locks. CI runs this standalone script AFTER Flutter tests exit.
// Every path is a unique test-only systemTemp directory.
import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:moodiary_data/moodiary_data.dart';
import 'package:moodiary_sync/src/data/mod_month_recovery_slot_v1.dart';
import 'package:path/path.dart' as p;

const topic='aac26e25-4a1d-4b4c-b256-9b0c347d36e2';
const oldId='generation_baseline_2026';
const newId='generation_incoming_2026';

Never fail(String message) => throw StateError('SIGKILL_MATRIX_FAILURE: '+message);
void check(bool valid,String message) { if (!valid) fail(message); }
bool same(List<int> a,List<int> b) {
  if (a.length!=b.length) return false;
  for (var i=0;i<a.length;i++) { if (a[i]!=b[i]) return false; }
  return true;
}

String packageConfig() {
  var current=Directory.current.absolute;
  while (true) {
    final file=File(p.join(current.path,'.dart_tool','package_config.json'));
    if (file.existsSync()) return file.path;
    if (current.parent.path==current.path) fail('package_config_missing');
    current=current.parent;
  }
}
List<String> childArgs(String config,String mode,List<String> args) => [
  '--packages='+config,
  p.absolute('test','sync','data','harness','real_sigkill_slot_child.dart'),
  mode,...args,
];

Future<String> fixture(Directory sandbox,String name,int value) async {
  final dir=Directory(p.join(sandbox.path,'real-sigkill-source-'+name));
  final sqlite=File(p.join(dir.path,'database','restored.sqlite'));
  await sqlite.parent.create(recursive:true);
  final media=File(p.join(dir.path,'media','image','current.png'));
  await media.parent.create(recursive:true);
  await media.writeAsBytes([137,80,78,71,value],flush:true);
  await File(p.join(dir.path,'media','image','historic.png'))
    .writeAsBytes([137,80,78,71,value,42],flush:true);
  final db=MoodiaryDatabase.forTesting(NativeDatabase(sqlite));
  try {
    await db.customSelect('SELECT 1').get();
    final document=jsonEncode({'type':'doc','attrs':{'v':2},'content':[
      {'type':'paragraph','content':[{'type':'text','text':name}]}]});
    await db.customStatement(
      'INSERT INTO diaries'
      '(id,title,content,content_text,time,last_modified,show,type)'
      ' VALUES(?,?,?,?,?,?,?,?)',
      [topic,'测试主题 '+name,document,name,
        1794038400000000,1794038400000000,1,'tiptap']);
    await db.customStatement(
      'INSERT INTO mod_month_pages'
      '(topic_id,month_key,diary_id,created_ms) VALUES(?,?,NULL,?)',
      [topic,'2026-11',100+value]);
    check((await ModMonthGraphArchiveV1.exportGraph(db)).contains('2026-11'),
      'source_graph_missing');
  } finally { await db.close(); }
  await File(p.join(dir.path,'restore-state.json')).writeAsString(jsonEncode({
    'format':'moodiary-isolated-restore','version':1,
    'phase':'ready','liveDataModified':false,
  }),flush:true);
  return dir.path;
}

Future<void> killAt(String dart,String config,String root,String source,
    String phase,String signal) async {
  final out=StringBuffer(),err=StringBuffer();
  final process=await Process.start(dart,
    childArgs(config,'install',[root,source,newId,phase,signal]),
    workingDirectory:Directory.current.path);
  process.stdout.transform(utf8.decoder).listen(out.write);
  process.stderr.transform(utf8.decoder).listen(err.write);
  int? exit;
  process.exitCode.then((code)=>exit=code);
  try {
    final deadline=DateTime.now().add(const Duration(seconds:55));
    while (!await File(signal).exists() && exit==null &&
        DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds:60));
    }
    if (!await File(signal).exists()) {
      fail('checkpoint_missing '+phase+' exit='+exit.toString()+
        ' stdout='+out.toString()+' stderr='+err.toString());
    }
    final marker=jsonDecode(await File(signal).readAsString());
    check(marker is Map && marker['phase']==phase,'wrong_checkpoint');
    check(marker['pid']==process.pid,'wrong_process_pid');
    check(exit==null,'child_exited_before_signal');
    check(process.kill(ProcessSignal.sigkill),'could_not_SIGKILL');
    final killed=await process.exitCode.timeout(const Duration(seconds:10));
    check(killed!=0,'normal_exit_instead_of_SIGKILL');
  } finally {
    process.kill(ProcessSignal.sigkill);
    try { await process.exitCode.timeout(const Duration(seconds:10)); }
    catch (_) {}
  }
}

Future<Map<String,dynamic>> recoverInNewProcess(
    String dart,String config,String root) async {
  final result=await Process.run(dart,
    childArgs(config,'recover',[root]),
    workingDirectory:Directory.current.path).timeout(
      const Duration(seconds:55));
  if (result.exitCode!=0) {
    fail('recovery_process_failed exit='+result.exitCode.toString()+
      ' stdout='+result.stdout.toString()+
      ' stderr='+result.stderr.toString());
  }
  final value=jsonDecode(result.stdout.toString().trim().split('\n').last);
  if (value is! Map<String,dynamic>) fail('bad_recovery_json');
  return value;
}

Future<void> main() async {
  if (!Platform.isLinux) {
    stdout.writeln('SIGKILL_MATRIX_SKIPPED non-Linux');
    return;
  }
  final dart=Platform.resolvedExecutable;
  check(File(dart).existsSync(),'missing_dart_vm_binary');
  final config=packageConfig();
  const all=[
    'journal_written','files_copied','generation_verified',
    'directory_moved','generation_installed',
    'pointer_written','journal_committed',
  ];
  final full=Platform.environment['MOODIARY_CRASH_MATRIX']=='full';
  final phases=full?all:['directory_moved','pointer_written'];
  final sandbox=await Directory.systemTemp.createTemp('w9772-sigkill-');
  try {
    final original=await fixture(sandbox,'baseline',11);
    final replacement=await fixture(sandbox,'incoming',12);
    for (var i=0;i<phases.length;i++) {
      final phase=phases[i];
      final root=p.join(sandbox.path,'real-sigkill-slot-'+i.toString());
      final slot=await ModMonthRecoverySlotV1.createNew(root);
      await slot.installVerified(
        sourceDirectory:original,generationId:oldId);
      final prev=await slot.currentDirectory();
      check(prev!=null && prev.contains(oldId),'baseline_missing');
      final marker=p.join(sandbox.path,'signal-'+i.toString()+'.json');
      await killAt(dart,config,root,replacement,phase,marker);
      final result=await recoverInNewProcess(dart,config,root);
      final committed=all.indexOf(phase)>=5;
      check(result['result']==(committed?'committed':'rolled_back'),
        'wrong_recovery_decision '+phase+' '+result.toString());
      check(result['active']==(committed?newId:oldId),
        'wrong_active_pointer '+phase+' '+result.toString());
      final reopened=await ModMonthRecoverySlotV1.openExisting(root);
      final active=await reopened.currentDirectory();
      check(active!=null && active.contains(committed?newId:oldId),
        'active_generation_not_readable '+phase);
      check(same(await File(p.join(prev!,'media','image','current.png'))
        .readAsBytes(),[137,80,78,71,11]),'old_media_changed '+phase);
      check(same(await File(p.join(prev,'media','image','historic.png'))
        .readAsBytes(),[137,80,78,71,11,42]),
        'old_history_changed '+phase);
      check(same(await File(p.join(original,'media','image','current.png'))
        .readAsBytes(),[137,80,78,71,11]),'source_old_changed '+phase);
      check(same(await File(p.join(replacement,'media','image','current.png'))
        .readAsBytes(),[137,80,78,71,12]),'source_new_changed '+phase);
      check(same(await File(p.join(active!,'media','image','current.png'))
        .readAsBytes(),[137,80,78,71,committed?12:11]),
        'active_media_wrong '+phase);
      check(await reopened.recover()=='clean','recovery_not_idempotent '+phase);
      check(!await Directory(p.join(root,'generations','.incoming-'+newId))
        .exists(),'uncommitted_stage_leaked '+phase);
      stdout.writeln('SIGKILL_OK phase='+phase+
        ' result='+result['result'].toString());
    }
    stdout.writeln('SIGKILL_MATRIX_PASS checkpoints='+phases.length.toString()+
      ' mode='+(full?'full':'smoke'));
  } finally {
    if (await sandbox.exists()) await sandbox.delete(recursive:true);
  }
}
