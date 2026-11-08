"""W9.8.4.6: fail-closed preview ownership guard and data-preserving tests."""
from pathlib import Path
import hashlib
import shutil
import sys

root=Path(sys.argv[1]).resolve()
here=Path(__file__).resolve().parent
library=Path(
    'packages/feature/moodiary_sync/lib/src/data/'
    'mod_month_zip_generation_install_v2.dart'
)
test_path=root/'packages/feature/moodiary_sync/test/sync/data/mod_month_isolated_restore_v2_test.dart'
expected_library_sha='7a74bfe6979535a0ac16cb9b4b233f16f3076d1f'
old_test_marker='ZIP-to-generation refuses duplicate generation IDs without overwriting existing data'

def git_blob_sha(data: bytes) -> str:
    return hashlib.sha1(
        ('blob '+str(len(data))+'\0').encode('ascii')+data
    ).hexdigest()

original=root/library
new=here/'overlay'/library
if not original.is_file() or not new.is_file():
    raise SystemExit('W9.8.4.6 source integration missing')
old_bytes=original.read_bytes()
new_bytes=new.read_bytes()
if old_bytes != new_bytes:
    if git_blob_sha(old_bytes) != expected_library_sha:
        raise SystemExit('W9.8.4.6 ZIP installer baseline mismatch; refusing replacement')
    shutil.copyfile(new,original)
    print('PATCHED: '+str(library))
else:
    print('ALREADY APPLIED: '+str(library))

if not test_path.is_file():
    raise SystemExit('W9.8.4.6 V2 integration test file is missing')
source=test_path.read_text(encoding='utf-8')
assertions=[
    'ZIP-to-generation protects foreign files added during the handoff',
    'ZIP-to-generation rejects replaced symlink preview without deleting user data',
    'ZIP-to-generation rejects modified media before cleanup',
]
if all(marker in source for marker in assertions):
    print('W9.8.4.6 preview ownership regression tests already present')
else:
    if old_test_marker not in source or any(marker in source for marker in assertions):
        raise SystemExit('W9.8.4.6 test baseline incomplete or partially applied')
    anchor="  test('full V2 ZIP cold restore: native Diary, two daily mappings, history and media',"
    if source.count(anchor)!=1:
        raise SystemExit('W9.8.4.6 test insertion point mismatch')
    new_tests=r'''
  test('ZIP-to-generation protects foreign files added during the handoff',
      () async {
    final zip=await buildZip();
    final preview=sandbox.path+'/preview-with-foreign-user-file';
    final slot=await ModMonthRecoverySlotV2.createNew(
      sandbox.path+'/foreign-file-slot');
    final userNotes=File(preview+'/not-part-of-restore.txt');
    await expectLater(
      ModMonthZipGenerationInstallV2.install(
        zipPath:zip,previewDirectory:preview,slot:slot,
        generationId:'generation_foreign_data_2026',
        isTopic:isTopic,transport:transport,
        checkpoint:(phase) async {
          if (phase=='restore:complete') {
            await userNotes.writeAsString('important user notes',flush:true);
            throw StateError('simulated handoff fault');
          }
        }),
      throwsA(isA<ModBundleInvalid>().having(
        (e)=>e.code,'code','preview_cleanup_unsafe')));
    expect(await userNotes.readAsString(),'important user notes');
    expect(await slot.currentDirectory(),isNull);
  });

  test('ZIP-to-generation rejects replaced symlink preview without deleting user data',
      () async {
    final zip=await buildZip();
    final preview=sandbox.path+'/preview-replaced-by-link';
    final protected=Directory(sandbox.path+'/real-user-diaries');
    await protected.create();
    final keep=File(protected.path+'/never-delete.txt');
    await keep.writeAsString('preserve-this-diary',flush:true);
    final slot=await ModMonthRecoverySlotV2.createNew(
      sandbox.path+'/symlink-swap-slot');
    await expectLater(
      ModMonthZipGenerationInstallV2.install(
        zipPath:zip,previewDirectory:preview,slot:slot,
        generationId:'generation_link_swap_2026',
        isTopic:isTopic,transport:transport,
        checkpoint:(phase) async {
          if (phase=='restore:complete') {
            await Directory(preview).rename(preview+'.original');
            await Link(preview).create(protected.path);
            throw StateError('simulated preview swap');
          }
        }),
      throwsA(isA<ModBundleInvalid>().having(
        (e)=>e.code,'code','preview_cleanup_unsafe')));
    expect(await keep.readAsString(),'preserve-this-diary');
    expect(await FileSystemEntity.type(preview,followLinks:false),
      FileSystemEntityType.link);
    expect(await slot.currentDirectory(),isNull);
  });

  test('ZIP-to-generation rejects modified media before cleanup',() async {
    final zip=await buildZip();
    final preview=sandbox.path+'/preview-mutated-media';
    final slot=await ModMonthRecoverySlotV2.createNew(
      sandbox.path+'/mutated-media-slot');
    final media=File(preview+'/media/image/history.png');
    await expectLater(
      ModMonthZipGenerationInstallV2.install(
        zipPath:zip,previewDirectory:preview,slot:slot,
        generationId:'generation_media_change_2026',
        isTopic:isTopic,transport:transport,
        checkpoint:(phase) async {
          if (phase=='restore:complete') {
            await media.writeAsBytes([2,3,5,7,11,13,17,19,23],flush:true);
            throw StateError('simulated preview media modification');
          }
        }),
      throwsA(isA<ModBundleInvalid>().having(
        (e)=>e.code,'code','preview_cleanup_unsafe')));
    expect(await media.readAsBytes(),
      orderedEquals([2,3,5,7,11,13,17,19,23]));
    expect(await slot.currentDirectory(),isNull);
  });

'''
    test_path.write_text(source.replace(anchor,new_tests+anchor,1),
        encoding='utf-8')
    print('W9.8.4.6: three preview ownership regression cases installed')

pub=root/'mobile/pubspec.yaml'
data=pub.read_text(encoding='utf-8')
old='version: 2.9.2+118'
new='version: 2.9.2+119'
if data.count(old)==1:
    pub.write_text(data.replace(old,new,1),encoding='utf-8')
elif data.count(new)==1:
    print('W9.8.4.6 app version already installed')
else:
    raise SystemExit('W9.8.4.6 version anchor mismatch')
print('W9.8.4.6 preview disposal hardening staged; production restore unchanged')
