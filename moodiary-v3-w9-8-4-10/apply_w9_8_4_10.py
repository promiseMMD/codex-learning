"""W9.8.4.10: non-mutating recovery inventory, data retention tests."""
from pathlib import Path
import shutil
import sys

root=Path(sys.argv[1]).resolve()
here=Path(__file__).resolve().parent
library=Path(
  'packages/feature/moodiary_sync/lib/src/data/'
  'mod_month_restore_inventory_v2.dart'
)
src=here/'overlay'/library
dest=root/library
test=root/'packages/feature/moodiary_sync/test/sync/data/mod_month_isolated_restore_v2_test.dart'

if not src.is_file() or not dest.parent.is_dir():
    raise SystemExit('W9.8.4.10 recovery inventory source missing')
if dest.exists():
    if dest.read_bytes()!=src.read_bytes():
        raise SystemExit('W9.8.4.10 inventory source collision')
else:
    shutil.copyfile(src,dest)
    print('ADDED: '+str(library))

if not test.is_file():
    raise SystemExit('W9.8.4.10 test baseline missing')
contents=test.read_text(encoding='utf-8')
import_anchor="import 'package:moodiary_sync/src/data/mod_month_android_restore_root_v2.dart';\n"
new_import="import 'package:moodiary_sync/src/data/mod_month_restore_inventory_v2.dart';\n"
if contents.count(import_anchor)!=1:
    raise SystemExit('W9.8.4.10 test import anchor mismatch')
if new_import not in contents:
    contents=contents.replace(import_anchor,import_anchor+new_import,1)
anchor="  test('full V2 ZIP cold restore: native Diary, two daily mappings, history and media',"
markers=[
 'V2 inventory is empty without any restore workspaces',
 'V2 inventory recognizes verified immutable generation without mutation',
 'V2 inventory keeps an interrupted journal without repairing it',
 'V2 inventory refuses to own unknown user files',
 'V2 inventory preserves a symlink replacing a workspace',
 'V2 inventory flags a replaced workspace identity and preserves bytes',
 'V2 inventory marks an unexpected preview for manual review',
 'V2 inventory preserves an unexpected file inside an owned workspace',
]
if all(x in contents for x in markers):
    print('W9.8.4.10 inventory regression tests already applied')
else:
    if any(x in contents for x in markers) or contents.count(anchor)!=1:
        raise SystemExit('W9.8.4.10 unexpected or partial test baseline')
    new_tests=r'''
  test('V2 inventory is empty without any restore workspaces',() async {
    final root=await ModMonthPrivateRestoreRootV2.createOrOpenForSupport(
      applicationSupportDirectory:sandbox.path);
    final snapshot=await ModMonthRestoreInventoryV2.inspect(root);
    expect(snapshot.entries,isEmpty);
    expect(snapshot.requiresExplicitRetentionDecision,false);
    expect(snapshot.hasUnverifiedItems,false);
    expect(snapshot.knownBytes,0);
  });

  test('V2 inventory recognizes verified immutable generation without mutation',
      () async {
    final zip=await buildZip();
    final root=await ModMonthPrivateRestoreRootV2.createOrOpenForSupport(
      applicationSupportDirectory:sandbox.path);
    final ws=await root.createNewWorkspace();
    final selected=await ws.install(
      zipPath:zip,generationId:'generation_inventory_2026',
      isTopic:isTopic,transport:transport);
    final proof=File(selected+'/media/image/history.png');
    final before=await proof.readAsBytes();
    final snap=await ModMonthRestoreInventoryV2.inspect(root);
    expect(snap.entries,hasLength(1));
    expect(snap.entries.single.state,ModRestoreInventoryStateV2.ready);
    expect(snap.entries.single.activeDirectory,selected);
    expect(snap.entries.single.bytes,greaterThan(before.length));
    expect(snap.entries.single.files,greaterThan(2));
    expect(snap.requiresExplicitRetentionDecision,true);
    expect(snap.hasUnverifiedItems,false);
    expect(await proof.readAsBytes(),orderedEquals(before));
    expect(await ws.currentDirectory(),selected);
  });

  test('V2 inventory keeps an interrupted journal without repairing it',
      () async {
    final root=await ModMonthPrivateRestoreRootV2.createOrOpenForSupport(
      applicationSupportDirectory:sandbox.path);
    final ws=await root.createNewWorkspace();
    final journal=File(ws.root+'/generation-slot/recovery-journal.json');
    await journal.writeAsString('{"unresolved":"do-not-touch"}',flush:true);
    final before=await journal.readAsBytes();
    final scan=await ModMonthRestoreInventoryV2.inspect(root);
    expect(scan.entries.single.state,
      ModRestoreInventoryStateV2.recoveryRequired);
    expect(scan.hasUnverifiedItems,true);
    expect(await journal.readAsBytes(),orderedEquals(before));
  });

  test('V2 inventory refuses to own unknown user files',() async {
    final root=await ModMonthPrivateRestoreRootV2.createOrOpenForSupport(
      applicationSupportDirectory:sandbox.path);
    final note=File(root.root+'/my-original-notes.txt');
    await note.writeAsString('keep this file',flush:true);
    final scan=await ModMonthRestoreInventoryV2.inspect(root);
    expect(scan.entries,hasLength(1));
    expect(scan.entries.single.state,
      ModRestoreInventoryStateV2.unrecognized);
    expect(scan.entries.single.bytes,isNull);
    expect(scan.requiresExplicitRetentionDecision,true);
    expect(await note.readAsString(),'keep this file');
  });

  test('V2 inventory preserves a symlink replacing a workspace',() async {
    final root=await ModMonthPrivateRestoreRootV2.createOrOpenForSupport(
      applicationSupportDirectory:sandbox.path);
    final target=Directory(sandbox.path+'/actual-user-data');
    await target.create();
    final userFile=File(target.path+'/kept.txt');
    await userFile.writeAsString('never-remove',flush:true);
    final link=Link(root.root+'/.moodiary-v2-private-restore-link');
    await link.create(target.path);
    final snap=await ModMonthRestoreInventoryV2.inspect(root);
    expect(snap.entries.single.state,
      ModRestoreInventoryStateV2.unrecognized);
    expect(await userFile.readAsString(),'never-remove');
    expect(await FileSystemEntity.type(link.path,followLinks:false),
      FileSystemEntityType.link);
  });

  test('V2 inventory flags a replaced workspace identity and preserves bytes',
      () async {
    final root=await ModMonthPrivateRestoreRootV2.createOrOpenForSupport(
      applicationSupportDirectory:sandbox.path);
    final ws=await root.createNewWorkspace();
    final marker=File(ws.root+'/workspace-identity.json');
    await marker.writeAsString('{}',flush:true);
    final result=await ModMonthRestoreInventoryV2.inspect(root);
    expect(result.entries.single.state,
      ModRestoreInventoryStateV2.needsReview);
    expect(result.entries.single.bytes,isNull);
    expect(await marker.readAsString(),'{}');
  });

  test('V2 inventory marks an unexpected preview for manual review',() async {
    final root=await ModMonthPrivateRestoreRootV2.createOrOpenForSupport(
      applicationSupportDirectory:sandbox.path);
    final ws=await root.createNewWorkspace();
    final note=File(ws.root+'/preview/uncommitted-entry.txt');
    await note.parent.create(recursive:true);
    await note.writeAsString('do-not-clean',flush:true);
    final scan=await ModMonthRestoreInventoryV2.inspect(root);
    expect(scan.entries.single.state,
      ModRestoreInventoryStateV2.needsReview);
    expect(scan.entries.single.bytes,greaterThan(0));
    expect(await note.readAsString(),'do-not-clean');
  });

  test('V2 inventory preserves an unexpected file inside an owned workspace',
      () async {
    final root=await ModMonthPrivateRestoreRootV2.createOrOpenForSupport(
      applicationSupportDirectory:sandbox.path);
    final ws=await root.createNewWorkspace();
    final unknown=File(ws.root+'/personal.txt');
    await unknown.writeAsString('kept',flush:true);
    final scan=await ModMonthRestoreInventoryV2.inspect(root);
    expect(scan.entries.single.state,
      ModRestoreInventoryStateV2.needsReview);
    expect(scan.hasUnverifiedItems,true);
    expect(await unknown.readAsString(),'kept');
  });

'''
    contents=contents.replace(anchor,new_tests+anchor,1)
    print('W9.8.4.10: eight recovery inventory retention tests installed')
test.write_text(contents,encoding='utf-8')
pub=root/'mobile/pubspec.yaml'
v=pub.read_text(encoding='utf-8')
a='version: 2.9.2+122'
b='version: 2.9.2+123'
if v.count(a)==1:
    pub.write_text(v.replace(a,b,1),encoding='utf-8')
elif v.count(b)!=1:
    raise SystemExit('W9.8.4.10 mobile version mismatch')
print('W9.8.4.10 immutable inventory applied; no production restore or deletion')
