// Real sealed full-history test fixture: native Diary, current and deleted-
// revision media, SHA receipts, day mapping. ZIP codec uses Python for CI.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:drift/native.dart';
import 'package:moodiary_data/moodiary_data.dart';
import 'package:moodiary_models/moodiary_models.dart';
import 'package:moodiary_sync/src/data/impl/local_archive.dart';
import 'package:moodiary_sync/src/data/mod_month_stream_stage_v2.dart';
import 'package:moodiary_sync/src/data/mod_month_verified_manifest_v2.dart';
import 'package:moodiary_sync/src/data/mod_month_zip_bundle_v2.dart';
import '../sync_test_harness.dart';

final class CloudTestZipTransport implements ModMonthZipTransportV2 {
  const CloudTestZipTransport();
  static Future<void> run(List<String> args) async {
    final result=await Process.run('python3',args);
    if(result.exitCode!=0)throw StateError(result.stderr.toString());
  }
  @override
  Future<void> create({
    required String archivePath,required String sourceDirectory,
    required List<String> entries,
  }) => run(['-c',r'''
import sys,os,zipfile
out,root,*names=sys.argv[1:]
with zipfile.ZipFile(out,'w') as z:
  for name in names:
    z.write(os.path.join(root,*name.split('/')),name,
            compress_type=zipfile.ZIP_STORED)
''',archivePath,sourceDirectory,...entries]);
  @override
  Future<void> extract({
    required String archivePath,required String destinationDirectory,
  }) => run(['-c',r'''
import sys,zipfile
with zipfile.ZipFile(sys.argv[1]) as z:
  z.extractall(sys.argv[2])
''',archivePath,destinationDirectory]);
}

final class CloudFullZipFixture {
  const CloudFullZipFixture(this.zip);
  final File zip;
  static const historicalMedia='media/image/history.png';
  static const currentMedia='media/image/current.png';
  static const historicalBytes=<int>[10,11,12,13,14];
  static const currentBytes=<int>[137,80,78,71,99,98,97];

  static Future<CloudFullZipFixture> create(Directory scratch, {
    String childRevisionId='cloud-history-revision-0002',
    bool includeChild=true,
    String? childImageName,
    bool childDeleted=true,
    String nativeTitle='cloud backup',
    List<int>? historicalMediaBytes,
  }) async {
    const topic='aac26e25-4a1d-4b4c-b256-9b0c347d36e2';
    const block='cloud-history-block-0001';
    const first='cloud-history-revision-0001';
    const month='2026-11',day='2026-11-11';
    final db=MoodiaryDatabase.forTesting(NativeDatabase.memory());
    try {
      final old=jsonEncode({'type':'doc','attrs':{'v':2},
        'content':[{'type':'image','attrs':{'src':'history.png'}}]});
      final edited=jsonEncode({'type':'doc','attrs':{'v':2},
        'content':[{'type':'paragraph','content':[
          {'type':'text','text':'edited history'}]},
          if(childImageName!=null)
            {'type':'image','attrs':{'src':childImageName}}]});
      final deleted=jsonEncode({'type':'doc','attrs':{'v':2},
        'content':[{'type':'paragraph','content':[
          {'type':'text','text':'deleted history'}]}]});
      await db.customStatement(
        'INSERT INTO mod_month_pages(topic_id,month_key,diary_id,created_ms)'
        ' VALUES(?,?,NULL,?)',[topic,month,10]);
      await db.customStatement(
        'INSERT INTO mod_month_blocks(block_id,topic_id,month_key,kind,created_ms)'
        ' VALUES(?,?,?,?,?)',[block,topic,month,'entry',11]);
      for(final (id,parent,body,deletedFlag,occurredMs) in [
        (first,null,old,false,12),
        if(includeChild)
          (childRevisionId,first,childDeleted?deleted:edited,childDeleted,14)
      ]) {
        await db.customStatement(
          'INSERT INTO mod_month_revisions'
          '(revision_id,block_id,parent_revision_id,month_key,day_key,'
          'occurred_at_ms,body_json,deleted,edited_at_ms)'
          ' VALUES(?,?,?,?,?,?,?,?,?)',
          [id,block,parent,month,day,occurredMs,body,deletedFlag?1:0,occurredMs+1]);
        final digest=sha256.convert(utf8.encode(jsonEncode([
          block,id,topic,month,'entry',parent,day,occurredMs,body,deletedFlag
        ]))).toString();
        await db.customStatement(
          'INSERT INTO mod_month_ops'
          '(operation_id,payload_sha256,block_id,revision_id,applied_at_ms)'
          ' VALUES(?,?,?,?,?)',
          ['operation-'+id,digest,block,id,occurredMs+1]);
      }
      await db.customStatement(
        'INSERT INTO mod_month_heads(block_id,revision_id) VALUES(?,?)',
        [block,includeChild?childRevisionId:first]);
      await db.customStatement(
        'INSERT INTO mod_day_pages'
        '(topic_id,day_key,diary_id,visible_local,created_ms)'
        ' VALUES(?,?,NULL,0,?)',[topic,day,15]);

      final media=Directory(scratch.path+'/media');
      for(final item in [
        (currentMedia,currentBytes),
        (historicalMedia,historicalMediaBytes??historicalBytes)
      ]) {
        final file=File(media.path+'/'+item.$1.substring(6));
        await file.parent.create(recursive:true);
        await file.writeAsBytes(item.$2);
      }
      final stage=await ModMonthStreamStageV2.create(
        scratch.path+'/sealed');
      final native=buildDiary(id:topic,title:nativeTitle,
        images:['current.png']).copyWith(
          tags:['__moodiary_mod_topic_v1']);
      await LocalArchive.writeArchive(
        sink:stage,diaries:[native],categories:const [],
        tombstones:const [],mediaBaseDir:media.path);
      await stage.addLocalFile(historicalMedia,
        media.path+'/image/history.png');
      if(includeChild && !childDeleted && childImageName!=null){
        final extra=File(media.path+'/image/'+childImageName);
        await extra.writeAsBytes(const [33,44,55,66]);
        await stage.addLocalFile('media/image/'+childImageName,extra.path);
      }
      await stage.addBytes(ModMonthVerifiedManifestV2.graphPath,
        Uint8List.fromList(utf8.encode(
          await ModMonthGraphArchiveV2.exportGraph(db))));
      bool isTopic(Diary diary)=>
        diary.tags.contains('__moodiary_mod_topic_v1');
      final published=await stage.publish(isTopic:isTopic);
      final zipPath=scratch.path+'/full-history.zip';
      await ModMonthZipBundleV2.createVerified(
        sourceDirectory:published,outputZip:zipPath,
        isTopic:isTopic,transport:const CloudTestZipTransport());
      return CloudFullZipFixture(File(zipPath));
    } finally {
      await db.close();
    }
  }

  Future<File> changedHistoricalMedia(String path,{
    bool remove=false,
  }) async {
    await CloudTestZipTransport.run(['-c',r'''
import sys,zipfile
src,dst,remove=sys.argv[1:]
with zipfile.ZipFile(src) as old,zipfile.ZipFile(dst,'w') as new:
  for name in old.namelist():
    if name=='media/image/history.png' and remove=='1':
      continue
    data=old.read(name)
    if name=='media/image/history.png':
      data=b'tampered-deleted-revision-media'
    new.writestr(name,data,compress_type=zipfile.ZIP_STORED)
''',zip.path,path,remove?'1':'0']);
    return File(path);
  }
}
