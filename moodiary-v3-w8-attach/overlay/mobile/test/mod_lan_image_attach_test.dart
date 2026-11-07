import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moodiary_data/moodiary_data.dart';
import 'package:moodiary_di/moodiary_di.dart';
import 'package:moodiary_mobile/app/home/mod_lan_image_attach.dart';
import 'package:moodiary_mobile/app/home/mod_lan_image_policy.dart';
import 'package:moodiary_mobile/app/home/mod_lan_image_staging.dart';
import 'package:moodiary_mobile/app/home/mod_lan_rich.dart';
import 'package:moodiary_mobile/app/home/mod_lan_write.dart';
import 'package:moodiary_storage/moodiary_storage.dart';
import 'package:moodiary_storage/testing.dart';

const noteId = 'a90c54e9-4826-4b44-925d-02c55cfbb824';
const imageName = 'image-12345678-aaaa-4bbb-8ccc-001122334455.png';

Map<String, dynamic> sampleDoc() => {
  'type': 'doc', 'attrs': {'v': 2},
  'content': [{'type':'paragraph','content':[{'type':'text','text':'设备日志'}]}],
};

List<int> fakePng() => [
  0x89,0x50,0x4e,0x47,13,10,26,10,
  0,0,0,13,0x49,0x48,0x44,0x52,
  0,0,0,40,0,0,0,30,...List<int>.filled(40,0),
];

void main() {
  setUpAll(() => getIt.registerSingleton<IKVStorage>(MemoryKVStorage()));
  group('W8.5 phone-authoritative image attachment', () {
    late Directory work;
    late Directory saved;
    late MoodiaryDatabase db;
    late DiaryRepository repository;
    late ModLanRichWriter rich;
    late ModLanImageStaging staging;
    late ModLanImageAttach attach;

    File imageFile(String name) => File(saved.path + '/' + name);
    Future<String> promote(ModLanStagedImage staged) async {
      await staged.file.copy(imageFile(imageName).path);
      return imageName;
    }
    Future<void> delete(String name) async {
      final f=imageFile(name);
      if(await f.exists()) await f.delete();
    }
    Future<String> revision() async =>
      ModLanWriteSafety.revision(await rich.load(noteId));
    Future<String> stage([String owner='paired-1']) async {
      final bytes=fakePng();
      final x=await staging.accept(
        ownerSession:owner,contentType:'image/png',
        contentLength:bytes.length,body:Stream.value(bytes),
      );
      return x.id;
    }

    setUp(() async {
      work=await Directory.systemTemp.createTemp('lan-attach-test-');
      saved=await Directory(work.path+'/library').create();
      db=MoodiaryDatabase.forTesting(NativeDatabase.memory());
      repository=DiaryRepository(db);
      rich=ModLanRichWriter(repository);
      staging=ModLanImageStaging(
        privateCacheRoot:Directory(work.path+'/stage'),
        verifyDecodedImage:(file,mime) async {
          expect(mime,'image/png');
          expect(await file.exists(),true);
        },
      );
      attach=ModLanImageAttach(
        repository:repository,staging:staging,
        promoteImage:promote,fileForImage:imageFile,deleteImage:delete,
      );
      await rich.create({'id':noteId,'title':'原始日志','document':sampleDoc()});
    });
    tearDown(() async {
      await staging.close();
      await db.close();
      await work.delete(recursive:true);
    });

    test('verified media appended and derived image list updated by CAS',() async {
      final staged=await stage();
      final result=await attach.appendStagedImage(
        diaryId:noteId,stageId:staged,ownerSession:'paired-1',
        revision:await revision(),
      );
      expect(result.imageName,[imageName]);
      final data=jsonDecode(result.content) as Map<String,dynamic>;
      final last=(data['content'] as List).last as Map;
      expect(last['type'],'image');
      expect((last['attrs'] as Map)['src'],imageName);
      expect(await imageFile(imageName).exists(),true);
      expect(staging.pendingCount,0);
      expect(ModLanRichDocument.canEdit(result),false,
        reason:'W7 cannot edit complex image diaries until W8.6');
      await expectLater(
        attach.appendStagedImage(diaryId:noteId,stageId:staged,
          ownerSession:'paired-1',revision:await revision()),
        throwsA(isA<ModLanImagePolicyException>().having(
          (x)=>x.code,'code','staged_image_not_found')),
      );
    });

    test('stale preflight rejects without promoting any image',() async {
      final staged=await stage();
      await expectLater(
        attach.appendStagedImage(diaryId:noteId,stageId:staged,
          ownerSession:'paired-1',revision:List.filled(64,'f').join()),
        throwsA(isA<ModLanWriteException>().having(
          (x)=>x.code,'code','stale_revision')),
      );
      expect((await rich.load(noteId)).imageName,isEmpty);
      expect(await imageFile(imageName).exists(),false);
      expect(staging.pendingCount,1);
    });

    test('phone edit during promotion forces CAS rollback',() async {
      final staged=await stage();
      final oldRev=await revision();
      final racer=ModLanImageAttach(
        repository:repository,staging:staging,fileForImage:imageFile,
        deleteImage:delete,
        promoteImage:(value) async {
          final before=await rich.load(noteId);
          await repository.updateADiary(
            newDiary:before.copyWith(title:'手机端改了标题',
              lastModified:DateTime.now().toUtc()),
          );
          return promote(value);
        },
      );
      await expectLater(
        racer.appendStagedImage(diaryId:noteId,stageId:staged,
          ownerSession:'paired-1',revision:oldRev),
        throwsA(isA<ModLanWriteException>().having(
          (x)=>x.code,'code','stale_revision')),
      );
      expect((await rich.load(noteId)).title,'手机端改了标题');
      expect((await rich.load(noteId)).imageName,isEmpty);
      expect(await imageFile(imageName).exists(),false);
      expect(staging.pendingCount,1);
    });

    test('foreign session cannot consume someone else staging',() async {
      final staged=await stage('paired-1');
      await expectLater(
        attach.appendStagedImage(diaryId:noteId,stageId:staged,
          ownerSession:'paired-2',revision:await revision()),
        throwsA(isA<ModLanImagePolicyException>().having(
          (x)=>x.code,'code','upload_session_mismatch')),
      );
      expect((await rich.load(noteId)).imageName,isEmpty);
      expect(staging.pendingCount,1);
    });

    test('wrong promoted bytes cause rollback without DB write',() async {
      final staged=await stage();
      final wrong=ModLanImageAttach(
        repository:repository,staging:staging,
        promoteImage:(value) async {
          await imageFile(imageName).writeAsBytes([1,2,3]);
          return imageName;
        },
        fileForImage:imageFile,deleteImage:delete,
      );
      await expectLater(
        wrong.appendStagedImage(diaryId:noteId,stageId:staged,
          ownerSession:'paired-1',revision:await revision()),
        throwsA(isA<ModLanImagePolicyException>().having(
          (x)=>x.code,'code','image_promote_integrity_failed')),
      );
      expect((await rich.load(noteId)).imageName,isEmpty);
      expect(await imageFile(imageName).exists(),false);
      expect(staging.pendingCount,1);
    });
  });
}
