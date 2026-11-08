"""W9.8.4.5: add failure-path tests for ZIP -> V2 generation installation."""
from pathlib import Path
import hashlib
import sys

root=Path(sys.argv[1]).resolve()
test_file=root/'packages/feature/moodiary_sync/test/sync/data/mod_month_isolated_restore_v2_test.dart'
expected_base_blob='d3f1db0c2b2f6ef9d5bafb5c8b5f11c5cf57ee25'

def git_blob_sha(raw: bytes) -> str:
    header=f'blob {len(raw)}\0'.encode('ascii')
    return hashlib.sha1(header+raw).hexdigest()

markers=[
    'ZIP-to-generation refuses an existing preview without modifying it',
    'ZIP-to-generation removes preview when restore checkpoint fails before promotion',
    'ZIP-to-generation rolls back an interrupted copy and preserves the previous generation',
    'ZIP-to-generation commits after pointer-write interruption and retains the previous generation',
    'ZIP-to-generation refuses duplicate generation IDs without overwriting existing data',
]
if not test_file.is_file():
    raise SystemExit('W9.8.4.5 V2 restore integration test is missing')
raw=test_file.read_bytes()
source=raw.decode('utf-8')
if all(marker in source for marker in markers):
    print('W9.8.4.5 integration failure matrix already applied')
else:
    actual=git_blob_sha(raw)
    if actual!=expected_base_blob:
        raise SystemExit(
            'W9.8.4.5 test baseline mismatch; refusing replacement: '
            +str(test_file)+' ('+actual+')'
        )
    anchor="  test('full V2 ZIP cold restore: native Diary, two daily mappings, history and media',"
    if source.count(anchor)!=1:
        raise SystemExit('W9.8.4.5 test insertion anchor mismatch')
    addition=r'''
  test('ZIP-to-generation refuses an existing preview without modifying it',
      () async {
    final zip=await buildZip();
    final preview=Directory(sandbox.path+'/existing-preview');
    await preview.create();
    final keep=File(preview.path+'/keep.txt');
    await keep.writeAsString('keep-existing-data',flush:true);
    final slot=await ModMonthRecoverySlotV2.createNew(
      sandbox.path+'/existing-preview-slot');
    await expectLater(
      ModMonthZipGenerationInstallV2.install(
        zipPath:zip,previewDirectory:preview.path,slot:slot,
        generationId:'generation_preview_conflict_2026',
        isTopic:isTopic,transport:transport),
      throwsA(isA<ModBundleInvalid>().having(
        (e)=>e.code,'code','restore_destination_exists')));
    expect(await keep.readAsString(),'keep-existing-data');
    expect(await slot.currentDirectory(),isNull);
  });

  test('ZIP-to-generation removes preview when restore checkpoint fails before promotion',
      () async {
    final zip=await buildZip();
    final preview=sandbox.path+'/restore-checkpoint-preview';
    final slot=await ModMonthRecoverySlotV2.createNew(
      sandbox.path+'/restore-checkpoint-slot');
    await expectLater(
      ModMonthZipGenerationInstallV2.install(
        zipPath:zip,previewDirectory:preview,slot:slot,
        generationId:'generation_restore_checkpoint_2026',
        isTopic:isTopic,transport:transport,
        checkpoint:(phase) async {
          if (phase=='restore:complete') {
            throw StateError('injected restore-to-slot handoff failure');
          }
        }),
      throwsA(isA<StateError>()));
    expect(await Directory(preview).exists(),false);
    expect(await slot.currentDirectory(),isNull);
  });

  test('ZIP-to-generation rolls back an interrupted copy and preserves the previous generation',
      () async {
    final zip=await buildZip();
    final oldReady=await ModMonthIsolatedRestoreV2
      .restoreZipToNewIsolatedDirectory(
        zipPath:zip,outputDirectory:sandbox.path+'/old-ready-copy',
        isTopic:isTopic,transport:transport);
    final slotPath=sandbox.path+'/copy-interruption-slot';
    final slot=await ModMonthRecoverySlotV2.createNew(slotPath);
    await slot.installVerified(
      sourceDirectory:oldReady,generationId:'generation_previous_2026');
    final previous=await slot.currentDirectory();
    expect(previous,isNotNull);
    await Directory(oldReady).delete(recursive:true);
    final preview=sandbox.path+'/copy-interruption-preview';
    await expectLater(
      ModMonthZipGenerationInstallV2.install(
        zipPath:zip,previewDirectory:preview,slot:slot,
        generationId:'generation_next_2026',
        isTopic:isTopic,transport:transport,
        checkpoint:(phase) async {
          if (phase=='slot:files_copied') {
            throw const ModSlotV2SimulatedProcessDeath('files_copied');
          }
        }),
      throwsA(isA<ModSlotV2SimulatedProcessDeath>()));
    expect(await Directory(preview).exists(),false);
    final reopened=await ModMonthRecoverySlotV2.openExisting(slotPath);
    await expectLater(
      reopened.currentDirectory(),
      throwsA(isA<ModBundleInvalid>().having(
        (e)=>e.code,'code','restart_recovery_required')));
    expect(await reopened.recover(),'rolled_back');
    expect(await reopened.currentDirectory(),previous);
    expect(await File(previous!+'/media/image/history.png').exists(),true);
    expect(await Directory(
      slotPath+'/generations/.incoming-generation_next_2026').exists(),false);
  });

  test('ZIP-to-generation commits after pointer-write interruption and retains the previous generation',
      () async {
    final zip=await buildZip();
    final oldReady=await ModMonthIsolatedRestoreV2
      .restoreZipToNewIsolatedDirectory(
        zipPath:zip,outputDirectory:sandbox.path+'/old-ready-commit',
        isTopic:isTopic,transport:transport);
    final slotPath=sandbox.path+'/pointer-interruption-slot';
    final slot=await ModMonthRecoverySlotV2.createNew(slotPath);
    await slot.installVerified(
      sourceDirectory:oldReady,generationId:'generation_previous_2026');
    final previous=await slot.currentDirectory();
    expect(previous,isNotNull);
    await Directory(oldReady).delete(recursive:true);
    final preview=sandbox.path+'/pointer-interruption-preview';
    await expectLater(
      ModMonthZipGenerationInstallV2.install(
        zipPath:zip,previewDirectory:preview,slot:slot,
        generationId:'generation_next_2026',
        isTopic:isTopic,transport:transport,
        checkpoint:(phase) async {
          if (phase=='slot:pointer_written') {
            throw const ModSlotV2SimulatedProcessDeath('pointer_written');
          }
        }),
      throwsA(isA<ModSlotV2SimulatedProcessDeath>()));
    expect(await Directory(preview).exists(),false);
    final reopened=await ModMonthRecoverySlotV2.openExisting(slotPath);
    await expectLater(
      reopened.currentDirectory(),
      throwsA(isA<ModBundleInvalid>().having(
        (e)=>e.code,'code','restart_recovery_required')));
    expect(await reopened.recover(),'committed');
    final active=await reopened.currentDirectory();
    expect(active,isNotNull);
    expect(active!.endsWith('/generation_next_2026'),isTrue);
    expect(await File(previous!+'/media/image/history.png').exists(),true);
    expect(await File(active+'/media/image/history.png').exists(),true);
  });

  test('ZIP-to-generation refuses duplicate generation IDs without overwriting existing data',
      () async {
    final zip=await buildZip();
    final oldReady=await ModMonthIsolatedRestoreV2
      .restoreZipToNewIsolatedDirectory(
        zipPath:zip,outputDirectory:sandbox.path+'/duplicate-ready',
        isTopic:isTopic,transport:transport);
    final slot=await ModMonthRecoverySlotV2.createNew(
      sandbox.path+'/duplicate-generation-slot');
    await slot.installVerified(
      sourceDirectory:oldReady,generationId:'generation_duplicate_2026');
    final previous=await slot.currentDirectory();
    expect(previous,isNotNull);
    await Directory(oldReady).delete(recursive:true);
    final preview=sandbox.path+'/duplicate-generation-preview';
    await expectLater(
      ModMonthZipGenerationInstallV2.install(
        zipPath:zip,previewDirectory:preview,slot:slot,
        generationId:'generation_duplicate_2026',
        isTopic:isTopic,transport:transport),
      throwsA(isA<ModBundleInvalid>().having(
        (e)=>e.code,'code','generation_already_exists')));
    expect(await Directory(preview).exists(),false);
    expect(await slot.currentDirectory(),previous);
    expect(await File(previous!+'/media/image/history.png').exists(),true);
  });

'''
    updated=source.replace(anchor,addition+anchor,1)
    test_file.write_text(updated,encoding='utf-8')
    print('W9.8.4.5: five ZIP-to-generation failure-path tests installed')

pub=root/'mobile/pubspec.yaml'
data=pub.read_text(encoding='utf-8')
old='version: 2.9.2+117'
new='version: 2.9.2+118'
if data.count(old)==1:
    pub.write_text(data.replace(old,new,1),encoding='utf-8')
elif data.count(new)==1:
    print('W9.8.4.5 app version already applied')
else:
    raise SystemExit('W9.8.4.5 version anchor mismatch')
print('W9.8.4.5 ZIP -> generation failure matrix staged')
