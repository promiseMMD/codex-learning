"""W9.8.4.7: preflight fence for preview vs isolated generation slot."""
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
test_file=root/'packages/feature/moodiary_sync/test/sync/data/mod_month_isolated_restore_v2_test.dart'
base_blob='8acf7584592ebaf1d9f5d4673b3fe71d92b76005'
anchor="  test('full V2 ZIP cold restore: native Diary, two daily mappings, history and media',"
markers=[
    'ZIP-to-generation refuses a preview nested inside the isolated slot root',
    'ZIP-to-generation refuses an alias through a symbolic-link parent',
    'ZIP-to-generation refuses a preview whose parent cannot be resolved',
]

def git_blob_sha(data: bytes) -> str:
    return hashlib.sha1(
        ('blob '+str(len(data))+'\0').encode('ascii')+data
    ).hexdigest()

old=root/library
new=here/'overlay'/library
if not old.is_file() or not new.is_file():
    raise SystemExit('W9.8.4.7 library path missing')
old_bytes=old.read_bytes()
new_bytes=new.read_bytes()
if old_bytes != new_bytes:
    if git_blob_sha(old_bytes)!=base_blob:
        raise SystemExit('W9.8.4.7 installer baseline mismatch; no changes')
    shutil.copyfile(new,old)
    print('PATCHED: '+str(library))
else:
    print('ALREADY APPLIED: '+str(library))

if not test_file.is_file():
    raise SystemExit('W9.8.4.7 integration tests missing')
source=test_file.read_text(encoding='utf-8')
if all(s in source for s in markers):
    print('W9.8.4.7 path overlap tests already installed')
else:
    if any(s in source for s in markers):
        raise SystemExit('W9.8.4.7 partial test patch, refusing edit')
    if source.count(anchor)!=1 or (
        'ZIP-to-generation rejects modified media before cleanup' not in source
    ):
        raise SystemExit('W9.8.4.7 unexpected test baseline')
    added=r'''
  test('ZIP-to-generation refuses a preview nested inside the isolated slot root',
      () async {
    final zip=await buildZip();
    final slot=await ModMonthRecoverySlotV2.createNew(
      sandbox.path+'/nested-preview-slot');
    final forbidden=slot.root+'/preview-child';
    await expectLater(
      ModMonthZipGenerationInstallV2.install(
        zipPath:zip,previewDirectory:forbidden,slot:slot,
        generationId:'generation_nested_preview_2026',
        isTopic:isTopic,transport:transport),
      throwsA(isA<ModBundleInvalid>().having(
        (e)=>e.code,'code','preview_slot_path_overlap')));
    expect(await Directory(forbidden).exists(),false);
    expect(await slot.currentDirectory(),isNull);
    expect(await File(slot.root+'/slot-identity.json').exists(),true);
  });

  test('ZIP-to-generation refuses an alias through a symbolic-link parent',
      () async {
    final zip=await buildZip();
    final slot=await ModMonthRecoverySlotV2.createNew(
      sandbox.path+'/symlink-parent-slot');
    final alias=Link(sandbox.path+'/slot-alias');
    await alias.create(slot.root);
    await expectLater(
      ModMonthZipGenerationInstallV2.install(
        zipPath:zip,previewDirectory:alias.path+'/preview-child',slot:slot,
        generationId:'generation_alias_preview_2026',
        isTopic:isTopic,transport:transport),
      throwsA(isA<ModBundleInvalid>().having(
        (e)=>e.code,'code','preview_slot_path_overlap')));
    expect(await Directory(slot.root+'/preview-child').exists(),false);
    expect(await slot.currentDirectory(),isNull);
    expect(await File(slot.root+'/slot-identity.json').exists(),true);
  });

  test('ZIP-to-generation refuses a preview whose parent cannot be resolved',
      () async {
    final zip=await buildZip();
    final slot=await ModMonthRecoverySlotV2.createNew(
      sandbox.path+'/missing-parent-slot');
    final forbidden=sandbox.path+'/absent-preview-parent/preview';
    await expectLater(
      ModMonthZipGenerationInstallV2.install(
        zipPath:zip,previewDirectory:forbidden,slot:slot,
        generationId:'generation_missing_parent_2026',
        isTopic:isTopic,transport:transport),
      throwsA(isA<ModBundleInvalid>().having(
        (e)=>e.code,'code','preview_isolation_unverifiable')));
    expect(await Directory(sandbox.path+'/absent-preview-parent').exists(),false);
    expect(await slot.currentDirectory(),isNull);
  });

'''
    test_file.write_text(source.replace(anchor,added+anchor,1),encoding='utf-8')
    print('W9.8.4.7: three path isolation regression tests installed')

pub=root/'mobile/pubspec.yaml'
text=pub.read_text(encoding='utf-8')
old_version='version: 2.9.2+119'
new_version='version: 2.9.2+120'
if text.count(old_version)==1:
    pub.write_text(text.replace(old_version,new_version,1),encoding='utf-8')
elif text.count(new_version)!=1:
    raise SystemExit('W9.8.4.7 app version anchor mismatch')
print('W9.8.4.7 preview-slot path fence staged')
