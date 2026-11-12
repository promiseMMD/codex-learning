import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

// Android device gate: run with a Flutter Android integration/device runner.
// A Linux CI pass cannot establish the presence of the external link command,
// Android app-storage support, or user-selected SAF document behavior.
void main() {
  test('Android app-private candidate publication is atomic and no-clobber',
      () async {
    if (!Platform.isAndroid) return;
    final root=await Directory.systemTemp.createTemp('android-link-gate-');
    try {
      // Separate staging and destination directories on the same volume
      // match the production same-parent quarantine strategy more closely.
      final staging=Directory('${root.path}/staging');
      final output=Directory('${root.path}/output');
      await staging.create();
      await output.create();
      final source=File('${staging.path}/verified.zip');
      final target=File('${output.path}/published.zip');
      final bytes=List<int>.generate(8192,(i)=>i%251);
      await source.writeAsBytes(bytes,flush:true);
      final result=await Process.run('link',[source.path,target.path]);
      expect(result.exitCode,0,
        reason:'Android must support the exact production link invocation; '
          'otherwise Gate A remains blocked: ${result.stderr}');
      expect(await FileSystemEntity.identical(source.path,target.path),true);
      expect(await target.readAsBytes(),orderedEquals(bytes));

      // A second publisher must never replace an existing candidate.
      final other=File('${staging.path}/different.zip');
      await other.writeAsBytes([9,8,7],flush:true);
      final collision=await Process.run('link',[other.path,target.path]);
      expect(collision.exitCode,isNot(0));
      expect(await target.readAsBytes(),orderedEquals(bytes));
      expect(await other.readAsBytes(),orderedEquals([9,8,7]));

      // A dangling symlink also occupies the final name. Do not follow it
      // or silently replace it during no-clobber publication.
      final dangling=Link('${output.path}/dangling.zip');
      await dangling.create('${output.path}/missing-target.zip');
      final symlinkCollision=await Process.run(
        'link',[other.path,dangling.path]);
      expect(symlinkCollision.exitCode,isNot(0));
      expect(await FileSystemEntity.type(dangling.path,
        followLinks:false),FileSystemEntityType.link);
      expect(await File('${output.path}/missing-target.zip').exists(),false);

      // Existing source and final bytes remain intact even after a failed
      // competing publication.
      expect(await source.readAsBytes(),orderedEquals(bytes));
      expect(await target.readAsBytes(),orderedEquals(bytes));
    } finally {
      await root.delete(recursive:true);
    }
  });
}
