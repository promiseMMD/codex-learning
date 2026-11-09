"""W9.8.4.9: Android platform-support-path binding for isolated V2 restore."""
from pathlib import Path
import shutil
import sys

root=Path(sys.argv[1]).resolve()
here=Path(__file__).resolve().parent
library=Path('packages/feature/moodiary_sync/lib/src/data/mod_month_android_restore_root_v2.dart')
source=here/'overlay'/library
target=root/library
test=root/'packages/feature/moodiary_sync/test/sync/data/mod_month_isolated_restore_v2_test.dart'

if not source.is_file() or not target.parent.is_dir():
    raise SystemExit('W9.8.4.9 source or library directory missing')
if target.exists():
    if target.read_bytes()!=source.read_bytes():
        raise SystemExit('W9.8.4.9 Android restore root library collision')
else:
    shutil.copyfile(source,target)
    print('ADDED: '+str(library))

if not test.is_file():
    raise SystemExit('W9.8.4.9 test baseline missing')
contents=test.read_text(encoding='utf-8')
import_anchor="import 'package:moodiary_sync/src/data/mod_month_private_restore_workspace_v2.dart';\n"
new_import="import 'package:moodiary_sync/src/data/mod_month_android_restore_root_v2.dart';\n"
if contents.count(import_anchor)!=1:
    raise SystemExit('W9.8.4.9 import anchor mismatch')
if new_import not in contents:
    contents=contents.replace(import_anchor,import_anchor+new_import,1)

anchor="  test('full V2 ZIP cold restore: native Diary, two daily mappings, history and media',"
markers=[
    'Android private root preserves unrelated diaries during ZIP recovery',
    'Android private root creation is idempotent without reusing workspaces',
    'Android private root refuses an existing foreign unmarked directory',
    'Android private root refuses a symlink alias without following it',
    'Android private root refuses forged identity without altering files',
    'Android private root rejects untrusted external workspace on reopen',
    'Android private root reopen never creates missing directories',
    'Android private restore facade fails closed outside Android',
]
if all(m in contents for m in markers):
    print('W9.8.4.9 regression tests already present')
else:
    if any(m in contents for m in markers) or contents.count(anchor)!=1:
        raise SystemExit('W9.8.4.9 partially applied or invalid test baseline')
    tests=r'''
  test('Android private root preserves unrelated diaries during ZIP recovery',
      () async {
    final zip=await buildZip();
    final keep=File(sandbox.path+'/database/moodiary.db');
    await keep.parent.create(recursive:true);
    await keep.writeAsString('unchanged-live-diary',flush:true);

    final root=await ModMonthPrivateRestoreRootV2.createOrOpenForSupport(
        applicationSupportDirectory:sandbox.path);
    expect(root.root.endsWith(
        '/'+ModMonthPrivateRestoreRootV2.directoryName),isTrue);
    final workspace=await root.createNewWorkspace();
    final active=await workspace.install(
        zipPath:zip,generationId:'generation_android_root_2026',
        isTopic:isTopic,transport:transport);
    final reopenedRoot=await ModMonthPrivateRestoreRootV2
        .openExistingForSupport(applicationSupportDirectory:sandbox.path);
    final reopened=await reopenedRoot.openExistingWorkspace(workspace.root);
    expect(await reopened.currentDirectory(),active);
    expect(await File(active+'/media/image/history.png').exists(),true);
    expect(await keep.readAsString(),'unchanged-live-diary');
  });

  test('Android private root creation is idempotent without reusing workspaces',
      () async {
    final a=await ModMonthPrivateRestoreRootV2.createOrOpenForSupport(
        applicationSupportDirectory:sandbox.path);
    final first=await a.createNewWorkspace();
    final record=File(first.root+'/non-restorable-user-note.txt');
    await record.writeAsString('do-not-delete',flush:true);

    final b=await ModMonthPrivateRestoreRootV2.createOrOpenForSupport(
        applicationSupportDirectory:sandbox.path);
    final second=await b.createNewWorkspace();
    expect(first.root,isNot(second.root));
    expect(a.root,b.root);
    expect(await record.readAsString(),'do-not-delete');
    expect(await Directory(second.root).exists(),isTrue);
  });

  test('Android private root refuses an existing foreign unmarked directory',
      () async {
    final foreign=Directory(sandbox.path+'/' +
        ModMonthPrivateRestoreRootV2.directoryName);
    await foreign.create();
    final notes=File(foreign.path+'/my-contents.txt');
    await notes.writeAsString('preserve-original',flush:true);
    await expectLater(ModMonthPrivateRestoreRootV2.createOrOpenForSupport(
        applicationSupportDirectory:sandbox.path),
      throwsA(isA<ModBundleInvalid>().having(
        (e)=>e.code,'code',
        'android_restore_private_root_identity_invalid')));
    expect(await notes.readAsString(),'preserve-original');
  });

  test('Android private root refuses a symlink alias without following it',
      () async {
    final foreign=Directory(sandbox.path+'/other-real-data');
    await foreign.create();
    final note=File(foreign.path+'/important.txt');
    await note.writeAsString('keep',flush:true);
    final link=Link(sandbox.path+'/' +
        ModMonthPrivateRestoreRootV2.directoryName);
    await link.create(foreign.path);
    await expectLater(ModMonthPrivateRestoreRootV2.createOrOpenForSupport(
        applicationSupportDirectory:sandbox.path),
      throwsA(isA<ModBundleInvalid>().having(
        (e)=>e.code,'code',
        'android_restore_private_root_not_directory')));
    expect(await note.readAsString(),'keep');
    expect(await FileSystemEntity.type(link.path,followLinks:false),
        FileSystemEntityType.link);
  });

  test('Android private root refuses forged identity without altering files',
      () async {
    final root=await ModMonthPrivateRestoreRootV2.createOrOpenForSupport(
        applicationSupportDirectory:sandbox.path);
    final userFile=File(root.root+'/foreign-user-file.txt');
    await userFile.writeAsString('important',flush:true);
    await File(root.root+'/private-root-identity.json')
        .writeAsString('{"format":"forged"}',flush:true);
    await expectLater(ModMonthPrivateRestoreRootV2.openExistingForSupport(
        applicationSupportDirectory:sandbox.path),
      throwsA(isA<ModBundleInvalid>().having(
        (e)=>e.code,'code',
        'android_restore_private_root_identity_invalid')));
    expect(await userFile.readAsString(),'important');
  });

  test('Android private root rejects untrusted external workspace on reopen',
      () async {
    final root=await ModMonthPrivateRestoreRootV2.createOrOpenForSupport(
        applicationSupportDirectory:sandbox.path);
    final other=Directory(sandbox.path+'/other-not-a-workspace');
    await other.create();
    final important=File(other.path+'/keep.md');
    await important.writeAsString('untouched',flush:true);
    await expectLater(root.openExistingWorkspace(other.path),
      throwsA(isA<ModBundleInvalid>().having(
        (e)=>e.code,'code','private_workspace_outside_root')));
    expect(await important.readAsString(),'untouched');
  });

  test('Android private root reopen never creates missing directories',
      () async {
    await expectLater(ModMonthPrivateRestoreRootV2.openExistingForSupport(
        applicationSupportDirectory:sandbox.path),
      throwsA(isA<ModBundleInvalid>().having(
        (e)=>e.code,'code','android_restore_private_root_not_directory')));
    expect(await Directory(sandbox.path+'/' +
        ModMonthPrivateRestoreRootV2.directoryName).exists(),false);
  });

  test('Android private restore facade fails closed outside Android',() async {
    if (!Platform.isAndroid) {
      await expectLater(ModMonthAndroidPrivateRestoreV2.createNew(),
        throwsA(isA<ModBundleInvalid>().having(
          (e)=>e.code,'code','android_restore_unsupported_platform')));
    }
  });

'''
    contents=contents.replace(anchor,tests+anchor,1)
    print('W9.8.4.9: eight binding and file-preservation cases installed')
test.write_text(contents,encoding='utf-8')

pub=root/'mobile/pubspec.yaml'
version=pub.read_text(encoding='utf-8')
old='version: 2.9.2+121'
new='version: 2.9.2+122'
if version.count(old)==1:
    pub.write_text(version.replace(old,new,1),encoding='utf-8')
elif version.count(new)!=1:
    raise SystemExit('W9.8.4.9 mobile version anchor mismatch')

print('W9.8.4.9 Android platform binding staged; production restore still disabled')
