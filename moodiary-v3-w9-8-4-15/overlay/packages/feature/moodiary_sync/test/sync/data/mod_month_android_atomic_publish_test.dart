import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

// Run on an Android emulator/device with the package's Flutter test runner.
// Linux CI cannot establish that Android ships the external 'link' command.
// This is a required device gate, not evidence of Android success by itself.
void main() {
  test('Android candidate hard-link publication is atomic and no-clobber',
      () async {
    if (!Platform.isAndroid) return;
    final dir=await Directory.systemTemp.createTemp('android-link-gate-');
    try {
      final source=File('${dir.path}/verified.zip');
      final target=File('${dir.path}/published.zip');
      final bytes=List<int>.generate(8192,(i)=>i%251);
      await source.writeAsBytes(bytes,flush:true);
      final result=await Process.run('link',[source.path,target.path]);
      expect(result.exitCode,0,
        reason:'Android must support the exact production link invocation; '
          'otherwise Gate A remains blocked: ${result.stderr}');
      expect(await FileSystemEntity.identical(source.path,target.path),true);
      expect(await target.readAsBytes(),orderedEquals(bytes));

      // A second publisher must not replace the existing final ZIP.
      final other=File('${dir.path}/different.zip');
      await other.writeAsBytes([9,8,7],flush:true);
      final collision=await Process.run('link',[other.path,target.path]);
      expect(collision.exitCode,isNot(0));
      expect(await target.readAsBytes(),orderedEquals(bytes));
      expect(await other.readAsBytes(),orderedEquals([9,8,7]));
    } finally {
      await dir.delete(recursive:true);
    }
  });

}
