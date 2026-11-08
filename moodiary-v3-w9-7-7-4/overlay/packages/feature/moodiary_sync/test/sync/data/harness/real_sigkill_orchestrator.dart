// W9.7.7.4: pure-Dart supervisor for real Flutter-engine SIGKILL tests.
// Only uniquely named test directories under systemTemp are ever used.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;

const testFile = 'test/sync/data/harness/real_sigkill_slot_child_test.dart';
const oldId = 'generation_baseline_2026';
const newId = 'generation_incoming_2026';
const allPhases = [
  'journal_written','files_copied','generation_verified',
  'directory_moved','generation_installed','pointer_written',
  'journal_committed',
];
Never fail(String value) => throw StateError('SIGKILL_FAILURE: '+value);
void check(bool condition, String message) {
  if (!condition) fail(message);
}
Map<String, String> env(String mode,String sandbox,String root,
    String phase,String signal) => {
  ...Platform.environment,
  'MOODIARY_TEST_MODE': mode,
  'MOODIARY_TEST_SANDBOX': sandbox,
  'MOODIARY_TEST_ROOT': root,
  'MOODIARY_TEST_PHASE': phase,
  'MOODIARY_TEST_SIGNAL': signal,
};
List<String> get args => ['test','--no-pub','--reporter','expanded',testFile];

Future<String> execute(String mode,String sandbox,String root,
    String phase,String signal) async {
  final r = await Process.run('flutter',args,
    workingDirectory:Directory.current.path,
    environment:env(mode,sandbox,root,phase,signal),
  ).timeout(const Duration(seconds:110));
  if (r.exitCode!=0) {
    fail('flutter_test_'+mode+'_failed code='+r.exitCode.toString()
      +' stdout='+r.stdout.toString()+' stderr='+r.stderr.toString());
  }
  return r.stdout.toString();
}
Future<void> killAt(String sandbox,String root,String phase,
    String signal) async {
  final stdoutBuffer=StringBuffer(),stderrBuffer=StringBuffer();
  final runner=await Process.start('flutter',args,
    workingDirectory:Directory.current.path,
    environment:env('install',sandbox,root,phase,signal));
  runner.stdout.transform(utf8.decoder).listen(stdoutBuffer.write);
  runner.stderr.transform(utf8.decoder).listen(stderrBuffer.write);
  int? status;
  runner.exitCode.then((value) => status=value);
  try {
    final deadline=DateTime.now().add(const Duration(seconds:80));
    while (!File(signal).existsSync() && status==null &&
        DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds:75));
    }
    if (!File(signal).existsSync()) {
      fail('checkpoint_missing '+phase+' exit='+status.toString()
        +' out='+stdoutBuffer.toString()+' err='+stderrBuffer.toString());
    }
    final receipt=jsonDecode(await File(signal).readAsString());
    check(receipt is Map && receipt['phase']==phase && receipt['root']==root,
      'bad_checkpoint_receipt');
    final testerPid=receipt['pid'];
    check(testerPid is int && testerPid>1 && status==null,
      'flutter_engine_child_missing');
    check(Process.killPid(testerPid as int,ProcessSignal.sigkill),
      'could_not_kill_flutter_engine_pid');
    final exit=await runner.exitCode.timeout(const Duration(seconds:30));
    check(exit!=0,'SIGKILL_not_observed');
    stdout.writeln('SIGKILL_CHILD_KILLED '+phase);
  } finally {
    runner.kill(ProcessSignal.sigkill);
    try { await runner.exitCode.timeout(const Duration(seconds:5)); }
    catch (_) {}
  }
}
Future<void> verifyBytes(String path,List<int> expected) async {
  final bytes=await File(path).readAsBytes();
  check(bytes.length==expected.length && 
    List.generate(bytes.length,(i)=>bytes[i]==expected[i]).every((x)=>x),
    'media_mismatch '+path);
}
Future<void> main() async {
  if (!Platform.isLinux) {
    stdout.writeln('SIGKILL_SKIP_NON_LINUX');
    return;
  }
  final full=Platform.environment['MOODIARY_CRASH_MATRIX']=='full';
  final selected=full?allPhases:['directory_moved','pointer_written'];
  final sandbox=await Directory.systemTemp.createTemp('w9774-crash-');
  try {
    for (var n=0;n<selected.length;n++) {
      final phase=selected[n],root=p.join(sandbox.path,'real-sigkill-slot-'+n.toString());
      final signal=p.join(sandbox.path,'checkpoint-'+n.toString()+'.json');
      final setup=await execute('prepare',sandbox.path,root,phase,signal);
      check(setup.contains('SIGKILL_SETUP_OK'),'missing_setup_receipt');
      await killAt(sandbox.path,root,phase,signal);
      final output=await execute('recover',sandbox.path,root,phase,signal);
      final at=output.indexOf('SIGKILL_RECOVER=');
      check(at>=0,'recovery_receipt_missing '+output);
      final raw=output.substring(at+'SIGKILL_RECOVER='.length).split('\n').first.trim();
      final recovered=jsonDecode(raw);
      check(recovered is Map,'bad_recovery_receipt');
      final committed=allPhases.indexOf(phase)>=5;
      check(recovered['result']==(committed?'committed':'rolled_back'),
        'wrong_recovery_decision '+phase+' '+raw);
      check(recovered['active']==(committed?newId:oldId),
        'wrong_active_generation '+phase+' '+raw);
      final mediaBase=p.join(root,'generations',oldId,'media','image');
      await verifyBytes(p.join(mediaBase,'current.png'),[137,80,78,71,11]);
      await verifyBytes(p.join(mediaBase,'historic.png'),[137,80,78,71,11,42]);
      await verifyBytes(p.join(sandbox.path,'real-sigkill-source-baseline',
          'media','image','current.png'),[137,80,78,71,11]);
      await verifyBytes(p.join(sandbox.path,'real-sigkill-source-incoming',
          'media','image','current.png'),[137,80,78,71,12]);
      await verifyBytes(p.join(root,'generations',committed?newId:oldId,
          'media','image','current.png'),[137,80,78,71,committed?12:11]);
      check(!Directory(p.join(root,'generations','.incoming-'+newId)).existsSync(),
        'leaked_incoming_dir '+phase);
      stdout.writeln('SIGKILL_OK '+phase);
    }
    stdout.writeln('SIGKILL_MATRIX_PASS count='+selected.length.toString());
  } finally {
    if (await sandbox.exists()) await sandbox.delete(recursive:true);
  }
}
