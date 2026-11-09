"""W9.8.4.8: isolate ZIP cold restore in a caller-supplied app-support root."""
from pathlib import Path
import shutil
import sys

root=Path(sys.argv[1]).resolve()
here=Path(__file__).resolve().parent
library=Path(
    'packages/feature/moodiary_sync/lib/src/data/'
    'mod_month_private_restore_workspace_v2.dart'
)
test=root/'packages/feature/moodiary_sync/test/sync/data/mod_month_isolated_restore_v2_test.dart'
source=here/'overlay'/library
target=root/library
if not source.is_file():
    raise SystemExit('W9.8.4.8 restore workspace source missing')
target.parent.mkdir(parents=True,exist_ok=True)
if target.exists():
    if target.read_bytes()!=source.read_bytes():
        raise SystemExit('W9.8.4.8 existing workspace source collision')
    print('ALREADY APPLIED: '+str(library))
else:
    shutil.copyfile(source,target)
    print('ADDED: '+str(library))

if not test.is_file():
    raise SystemExit('W9.8.4.8 ZIP restore test fixture missing')
contents=test.read_text(encoding='utf-8')
new_import="import 'package:moodiary_sync/src/data/mod_month_private_restore_workspace_v2.dart';\n"
import_anchor="import 'package:moodiary_sync/src/data/mod_month_zip_generation_install_v2.dart';\n"
if contents.count(import_anchor)!=1:
    raise SystemExit('W9.8.4.8 test import anchor mismatch')
if new_import not in contents:
    contents=contents.replace(import_anchor,import_anchor+new_import,1)

anchor="  test('full V2 ZIP cold restore: native Diary, two daily mappings, history and media',"
markers=[
    'private workspace installs a verified isolated ZIP and reopens cleanly',
    'private workspace refuses a symlinked caller-provided root',
    'private workspace refuses forged identity before reading data',
    'private workspace never overwrites a foreign preview directory',
    'private workspace refuses archives located inside its own directory',
    'private workspace cannot reopen an unrelated path',
]
if all(m in contents for m in markers):
    print('W9.8.4.8 workspace regression tests already installed')
else:
    if any(m in contents for m in markers) or contents.count(anchor)!=1:
        raise SystemExit('W9.8.4.8 unexpected or partially applied test baseline')
    new_tests=r'''
  test('private workspace installs a verified isolated ZIP and reopens cleanly',
      () async {
    final zip=await buildZip();
    final userFile=File(sandbox.path+'/unrelated-real-diary.txt');
    await userFile.writeAsString('must-preserve',flush:true);
    final workspace=await ModMonthPrivateRestoreWorkspaceV2.createNew(
      sandbox.path);
    expect(workspace.root.startsWith(sandbox.path+'/'),isTrue);
    final active=await workspace.install(
      zipPath:zip,generationId:'generation_workspace_2026',
      isTopic:isTopic,transport:transport);
    expect(active.endsWith('/generation_workspace_2026'),isTrue);
    expect(await Directory(workspace.root+'/preview').exists(),false);
    final reopened=await ModMonthPrivateRestoreWorkspaceV2.openExisting(
      applicationSupportDirectory:sandbox.path,
      workspaceDirectory:workspace.root);
    expect(await reopened.currentDirectory(),active);
    expect(await reopened.recover(),'clean');
    expect(await File(active+'/media/image/history.png').exists(),true);
    expect(await userFile.readAsString(),'must-preserve');
  });

  test('private workspace refuses a symlinked caller-provided root',() async {
    final alias=Link(sandbox.path+'/fake-app-support');
    await alias.create(sandbox.path);
    await expectLater(
      ModMonthPrivateRestoreWorkspaceV2.createNew(alias.path),
      throwsA(isA<ModBundleInvalid>().having(
        (e)=>e.code,'code','private_root_not_regular_directory')));
    expect(await FileSystemEntity.type(alias.path,followLinks:false),
      FileSystemEntityType.link);
  });

  test('private workspace refuses forged identity before reading data',() async {
    final zip=await buildZip();
    final workspace=await ModMonthPrivateRestoreWorkspaceV2.createNew(
      sandbox.path);
    await File(workspace.root+'/workspace-identity.json')
      .writeAsString('{}',flush:true);
    await expectLater(
      workspace.install(
        zipPath:zip,generationId:'generation_forged_identity_2026',
        isTopic:isTopic,transport:transport),
      throwsA(isA<ModBundleInvalid>().having(
        (e)=>e.code,'code','private_workspace_identity_invalid')));
    expect(await Directory(workspace.root+'/preview').exists(),false);
    expect(await File(zip).exists(),true);
  });

  test('private workspace never overwrites a foreign preview directory',
      () async {
    final zip=await buildZip();
    final workspace=await ModMonthPrivateRestoreWorkspaceV2.createNew(
      sandbox.path);
    final foreign=File(workspace.root+'/preview/foreign.txt');
    await foreign.parent.create(recursive:true);
    await foreign.writeAsString('private-record',flush:true);
    await expectLater(
      workspace.install(
        zipPath:zip,generationId:'generation_foreign_preview_2026',
        isTopic:isTopic,transport:transport),
      throwsA(isA<ModBundleInvalid>().having(
        (e)=>e.code,'code','preview_destination_exists')));
    expect(await foreign.readAsString(),'private-record');
    expect(await workspace.currentDirectory(),isNull);
  });

  test('private workspace refuses archives located inside its own directory',
      () async {
    final zip=await buildZip();
    final workspace=await ModMonthPrivateRestoreWorkspaceV2.createNew(
      sandbox.path);
    final privateZip=await File(zip).copy(workspace.root+'/inside.zip');
    await expectLater(
      workspace.install(
        zipPath:privateZip.path,
        generationId:'generation_inside_zip_2026',
        isTopic:isTopic,transport:transport),
      throwsA(isA<ModBundleInvalid>().having(
        (e)=>e.code,'code','private_restore_archive_inside_workspace')));
    expect(await privateZip.exists(),true);
    expect(await Directory(workspace.root+'/preview').exists(),false);
    expect(await workspace.currentDirectory(),isNull);
  });

  test('private workspace cannot reopen an unrelated path',() async {
    await expectLater(
      ModMonthPrivateRestoreWorkspaceV2.openExisting(
        applicationSupportDirectory:sandbox.path,
        workspaceDirectory:sandbox.path),
      throwsA(isA<ModBundleInvalid>().having(
        (e)=>e.code,'code','private_workspace_outside_root')));
  });

'''
    contents=contents.replace(anchor,new_tests+anchor,1)
    print('W9.8.4.8: six isolated private-workspace tests installed')
test.write_text(contents,encoding='utf-8')

pub=root/'mobile/pubspec.yaml'
version=pub.read_text(encoding='utf-8')
old='version: 2.9.2+120'
new='version: 2.9.2+121'
if version.count(old)==1:
    pub.write_text(version.replace(old,new,1),encoding='utf-8')
elif version.count(new)!=1:
    raise SystemExit('W9.8.4.8 expected mobile build version not found')
print('W9.8.4.8 workspace staged; live restore remains disabled')
