// W9.7.7.2: REAL Linux SIGKILL + cold Dart-process restart acceptance.
//
// This uses test-only physical SQLite and media in a unique systemTemp dir.
// No real app path, production database or WebDAV endpoint is ever opened.
import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moodiary_data/moodiary_data.dart';
import 'package:moodiary_sync/src/data/mod_month_recovery_slot_v1.dart';
import 'package:path/path.dart' as p;

const _topic='aac26e25-4a1d-4b4c-b256-9b0c347d36e2';
const _baselineId='generation_baseline_2026';
const _incomingId='generation_incoming_2026';

void main() {
  late Directory scratch;

  setUp(() async {
    scratch=await Directory.systemTemp.createTemp('w9772-real-sigkill-');
  });
  tearDown(() async {
    if (await scratch.exists()) await scratch.delete(recursive:true);
  });

  Future<String> createSource(String label,int marker) async {
    final dir=Directory(p.join(scratch.path,'real-sigkill-source-'+label));
    final file=File(p.join(dir.path,'database','restored.sqlite'));
    await file.parent.create(recursive:true);
    final media=File(p.join(dir.path,'media','image','current.png'));
    await media.parent.create(recursive:true);
    await media.writeAsBytes([137,80,78,71,marker],flush:true);
    final revision=File(p.join(dir.path,'media','image','historic.png'));
    await revision.writeAsBytes([137,80,78,71,marker,42],flush:true);
    final db=MoodiaryDatabase.forTesting(NativeDatabase(file));
    try {
      await db.customSelect('SELECT 1').get();
      final doc=jsonEncode({'type':'doc','attrs':{'v':2},'content':[
        {'type':'paragraph','content':[{'type':'text','text':label}]},
      ]});
      await db.customStatement(
        'INSERT INTO diaries'
        '(id,title,content,content_text,time,last_modified,show,type)'
        ' VALUES(?,?,?,?,?,?,?,?)',[
          _topic,'主题 '+label,doc,label,
          1794038400000000,1794038400000000,1,'tiptap',
        ]);
      await db.customStatement(
        'INSERT INTO mod_month_pages'
        '(topic_id,month_key,diary_id,created_ms) VALUES(?,?,NULL,?)',
        [_topic,'2026-11',marker+100]);
      expect(await ModMonthGraphArchiveV1.exportGraph(db),contains('2026-11'));
    } finally {
      await db.close();
    }
    await File(p.join(dir.path,'restore-state.json')).writeAsString(
      jsonEncode({
        'format':'moodiary-isolated-restore',
        'version':1,'phase':'ready','liveDataModified':false,
      }),flush:true);
    return dir.path;
  }

  String packageConfigPath() {
    var directory=Directory.current.absolute;
    while (true) {
      final candidate=File(p.join(directory.path,'.dart_tool','package_config.json'));
      if (candidate.existsSync()) return candidate.path;
      final parent=directory.parent;
      if (parent.path==directory.path) {
        throw StateError('missing_flutter_workspace_package_config');
      }
      directory=parent;
    }
  }

  List<String> childArgs(String config,String action,List<String> args) => [
    '--packages='+config,
    p.absolute('test','sync','data','harness','real_sigkill_slot_child.dart'),
    action,
    ...args,
  ];

  // Never use Platform.resolvedExecutable here: inside flutter test it is
  // flutter_tester, not the independent Dart CLI process we must SIGKILL.
  Future<String> killAtPhase(
      String config,String root,String from,String phase,String signal) async {
    final output=StringBuffer();
    final errors=StringBuffer();
    final process=await Process.start('dart',
      childArgs(config,'install',[root,from,_incomingId,phase,signal]),
      workingDirectory:Directory.current.path,
    );
    process.stdout.transform(utf8.decoder).listen(output.write);
    process.stderr.transform(utf8.decoder).listen(errors.write);
    int? exited;
    process.exitCode.then((code) => exited=code);
    try {
      final until=DateTime.now().add(const Duration(seconds:30));
      while (!await File(signal).exists() &&
          exited==null && DateTime.now().isBefore(until)) {
        await Future<void>.delayed(const Duration(milliseconds:50));
      }
      if (!await File(signal).exists()) {
        fail('child did not reach $phase; exit=$exited, '
          'stdout=$output, stderr=$errors');
      }
      final value=jsonDecode(await File(signal).readAsString());
      expect(value['phase'],phase);
      expect(value['pid'],process.pid);
      expect(exited,isNull,reason:'actual process must be alive at $phase');
      expect(process.kill(ProcessSignal.sigkill),isTrue);
      final code=await process.exitCode.timeout(const Duration(seconds:10));
      expect(code,isNot(0),reason:'SIGKILL cannot be a normal exit');
      return code.toString();
    } finally {
      process.kill(ProcessSignal.sigkill);
      try {
        await process.exitCode.timeout(const Duration(seconds:10));
      } catch (_) {}
    }
  }

  Future<Map<String,dynamic>> coldRestart(
      String config,String root) async {
    final result=await Process.run(
      'dart',childArgs(config,'recover',[root]),
      workingDirectory:Directory.current.path,
    ).timeout(const Duration(seconds:30));
    expect(result.exitCode,0,
      reason:'real restarted process stderr: '+result.stderr.toString());
    final output=result.stdout.toString().trim().split('\n').last;
    final parsed=jsonDecode(output);
    expect(parsed,isA<Map<String,dynamic>>());
    return parsed as Map<String,dynamic>;
  }

  test('real Linux SIGKILL across durable journal and pointer boundaries',
      () async {
    if (!Platform.isLinux) {
      // GitHub Actions uses Linux; Android device kill/boot QA is separate.
      return;
    }
    final config=packageConfigPath();
    // Fast CI covers pre/post pointer; full CI requires every checkpoint.
    final all=const [
      'journal_written',
      'files_copied',
      'generation_verified',
      'directory_moved',
      'generation_installed',
      'pointer_written',
      'journal_committed',
    ];
    final checkpoints=Platform.environment['MOODIARY_CRASH_MATRIX']=='full'
      ? all : ['directory_moved','pointer_written'];

    final oldSource=await createSource('old',11);
    final newSource=await createSource('next',12);

    for (var n=0;n<checkpoints.length;n++) {
      final phase=checkpoints[n];
      final base=p.join(scratch.path,'real-sigkill-slot-'+n.toString());
      final slot=await ModMonthRecoverySlotV1.createNew(base);
      await slot.installVerified(
        sourceDirectory:oldSource,generationId:_baselineId);
      final previous=await slot.currentDirectory();
      expect(previous,contains(_baselineId));
      final signal=p.join(scratch.path,'kill-signal-'+n.toString()+'.json');

      await killAtPhase(config,base,newSource,phase,signal);

      // A NEW independent OS process reads the disk after the killed
      // process's lock descriptor has been forcibly closed by the kernel.
      final resumed=await coldRestart(config,base);
      final pointerWasCommitted=all.indexOf(phase)>=5;
      expect(resumed['result'],
        pointerWasCommitted?'committed':'rolled_back',
        reason:'recover after actual SIGKILL at $phase');
      expect(resumed['active'],
        pointerWasCommitted?_incomingId:_baselineId,
        reason:'the pointer, not the journal phase, is commit boundary');

      final newReader=await ModMonthRecoverySlotV1.openExisting(base);
      final active=await newReader.currentDirectory();
      expect(active,contains(pointerWasCommitted?_incomingId:_baselineId));
      // Never lose the original independent generation or its media.
      expect(await File(p.join(previous!,'media','image','current.png'))
        .readAsBytes(),[137,80,78,71,11]);
      expect(await File(p.join(previous,'media','image','historic.png'))
        .readAsBytes(),[137,80,78,71,11,42]);
      expect(await File(p.join(oldSource,'media','image','current.png'))
        .readAsBytes(),[137,80,78,71,11]);
      expect(await File(p.join(newSource,'media','image','current.png'))
        .readAsBytes(),[137,80,78,71,12]);

      final actual=await File(p.join(active!,'media','image','current.png'))
        .readAsBytes();
      expect(actual,[137,80,78,71,pointerWasCommitted?12:11]);
      expect(await newReader.recover(),'clean',
        reason:'restart recovery must be idempotent');
      expect(await Directory(p.join(base,'generations',
        '.incoming-'+_incomingId)).exists(),isFalse);
    }
  },timeout:const Timeout(Duration(minutes:8)));
}
