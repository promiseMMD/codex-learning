// W9.7.7.2: separate REAL OS process used by the SIGKILL integration test.
//
// Never point this harness at real app storage. Only test-owned directories,
// explicitly created by the parent test, are accepted. Do not install this
// command in the mobile app or invoke it from user-facing backup/restore UI.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:moodiary_sync/src/data/mod_month_recovery_slot_v1.dart';
import 'package:path/path.dart' as p;

Future<void> main(List<String> args) async {
  if (args.isEmpty || !const ['install','recover'].contains(args.first)) {
    stderr.writeln('expected install|recover');
    exitCode=64;
    return;
  }
  try {
    final root=p.normalize(p.absolute(args[1]));
    // Fail closed unless the parent explicitly chose a temporary test slot.
    if (!p.basename(root).startsWith('real-sigkill-slot-')) {
      throw StateError('refuse_non_test_slot');
    }
    final slot=await ModMonthRecoverySlotV1.openExisting(root);
    if (args.first=='recover') {
      if (args.length!=2) throw StateError('recover_arity');
      final result=await slot.recover();
      final current=await slot.currentDirectory();
      stdout.writeln(jsonEncode({
        'result':result,
        'active':current==null?null:p.basename(current),
      }));
      return;
    }
    if (args.length!=6) throw StateError('install_arity');
    final source=p.normalize(p.absolute(args[2]));
    final generation=args[3];
    final stopAt=args[4];
    final signal=File(p.normalize(p.absolute(args[5])));
    if (!p.basename(source).startsWith('real-sigkill-source-') ||
        p.dirname(source)!=p.dirname(root) ||
        p.dirname(signal.path)!=p.dirname(root)) {
      throw StateError('untrusted_test_paths');
    }
    await slot.installVerified(
      sourceDirectory:source,
      generationId:generation,
      checkpoint:(phase) async {
        if (phase==stopAt) {
          // Durable signal arrives AFTER the precise slot checkpoint has
          // written to disk. The parent kills this process with SIGKILL.
          await signal.writeAsString(
            jsonEncode({'phase':phase,'pid':pid}),flush:true);
          // No exception: this Future intentionally remains pending until
          // OS SIGKILL. No catch/finally/unlock in installVerified executes.
          await Completer<void>().future;
        }
      },
    );
    // A successful return is a test failure: the parent was supposed to
    // kill this child at a checkpoint, not let the operation finish.
    stderr.writeln('missing_requested_kill_checkpoint: $stopAt');
    exitCode=66;
  } catch (error,trace) {
    stderr.writeln('SIGKILL child error: $error');
    stderr.writeln(trace);
    exitCode=65;
  }
}
