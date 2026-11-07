import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moodiary_data/moodiary_data.dart';
import 'package:moodiary_di/moodiary_di.dart';
import 'package:moodiary_mobile/app/home/mod_continuous.dart';
import 'package:moodiary_mobile/app/home/mod_lan_month_http.dart';
import 'package:moodiary_mobile/app/home/mod_month_native.dart';
import 'package:moodiary_mobile/app/home/mod_month_store.dart';
import 'package:moodiary_models/moodiary_models.dart';
import 'package:moodiary_storage/moodiary_storage.dart';
import 'package:moodiary_storage/testing.dart';

const topicId = 'aac26e25-4a1d-4b4c-b256-9b0c347d36e2';
const month = '2026-11';
String body(String text) => jsonEncode({'type':'doc','attrs':{'v':2},'content':[
  {'type':'paragraph','content':[{'type':'text','text':text,'marks':[{'type':'bold'}]}]}]});

void main() {
  setUpAll(() => getIt.registerSingleton<IKVStorage>(MemoryKVStorage()));
  tearDownAll(getIt.reset);
  late MoodiaryDatabase db;
  late DiaryRepository diaries;
  late ModNativeMonthRepository native;
  late Diary topic;
  late List<String> notifications;
  var counter = 0;

  ModMonthMutation operation({ModStoredBlock? base, String? text,
    String date = '2026-11-07', bool deleted = false, bool summary = false}) {
    final id = ++counter;
    return ModMonthMutation(operationId: 'native-op-$id', revisionId: 'native-rev-$id',
      blockId: base?.blockId ?? 'native-block-$id', topicId: topicId,
      monthKey: date.substring(0,7), kind: base?.kind ?? (summary ? 'summary' : 'entry'),
      parentRevisionId: base?.revisionId,
      dayKey: summary || base?.kind == 'summary' ? null : date,
      occurredAtMs: base?.occurredAtMs ?? 1794038400123,
      tiptapJson: text == null && base != null ? base.tiptapJson : body(text ?? '中文记录'),
      deleted: deleted);
  }

  setUp(() async {
    counter = 0;
    notifications = [];
    db = MoodiaryDatabase.forTesting(NativeDatabase.memory(
      setup: (sqlite) => sqlite.execute('PRAGMA foreign_keys = ON')));
    diaries = DiaryRepository(db);
    topic = Diary.create(title: '工作记录', content: body('主题'), contentText: '主题',
      imageName: [], audioName: [], videoName: [], tags: [ModDiary.topicTag],
      type: DiaryType.tiptap).copyWith(id: topicId);
    await diaries.insertADiary(topic);
    native = ModNativeMonthRepository(store: ModMonthStore(db), diaries: diaries,
      onCommitted: notifications.add);
  });
  tearDown(() async => db.close());

  test('discovery is read-only and does not create a Diary or month row', () async {
    final snapshot = await native.load(topicId, month);
    expect(snapshot.months, [month]);
    expect(snapshot.blocks, isEmpty);
    expect((await db.customSelect('SELECT COUNT(*) AS n FROM mod_month_pages').getSingle()).read<int>('n'), 0);
    expect((await diaries.getAllDiaries()).map((d)=>d.id), [topicId]);
  });

  test('native create/edit preserves rich marks, event precision and stable identity', () async {
    final first = await native.commit(operation());
    final second = await native.commit(operation(base:first,text:'正文修改'));
    expect(second.blockId, first.blockId);
    expect(second.parentRevisionId, first.revisionId);
    expect(second.occurredAtMs, 1794038400123);
    expect(second.tiptapJson, contains('bold'));
    expect(modBlockText(second.tiptapJson), '正文修改');
    expect((await native.load(topicId,month)).blocks.single.revisionId, second.revisionId);
    expect((await diaries.getAllDiaries()).length, 1);
    expect(notifications, [topicId,topicId]);
  });

  test('identical retry after another edit returns its own receipt without reverting head', () async {
    final attempt = operation();
    final first = await native.commit(attempt);
    final latest = await native.commit(operation(base:first,text:'后续修改'));
    final replay = await native.commit(attempt);
    expect(replay.revisionId, first.revisionId);
    expect((await native.load(topicId,month)).blocks.single.revisionId, latest.revisionId);
    expect((await db.customSelect('SELECT COUNT(*) AS n FROM mod_month_blocks').getSingle()).read<int>('n'), 1);
  });

  test('native refuses a stale PC parent and leaves both draft and saved block intact', () async {
    final first = await native.commit(operation());
    final draft = operation(base:first,text:'未覆盖的手机草稿');
    final pc = operation(base:first,text:'PC 最新内容');
    await native.store.appendRevision(operationId:pc.operationId,blockId:pc.blockId,
      revisionId:pc.revisionId,topicId:pc.topicId,monthKey:pc.monthKey,kind:pc.kind,
      parentRevisionId:pc.parentRevisionId,dayKey:pc.dayKey,
      occurredAtMs:pc.occurredAtMs,tiptapJson:pc.tiptapJson);
    await expectLater(native.commit(draft), throwsA(isA<ModMonthStoreException>()
      .having((e)=>e.code,'code','stale_revision')));
    expect(draft.toJson()['document'], jsonDecode(body('未覆盖的手机草稿')));
    expect((await native.load(topicId,month)).blocks.single.tiptapJson, body('PC 最新内容'));
  });

  test('cross-month edit moves the same block and keeps old and new revision history', () async {
    final first = await native.commit(operation());
    final moved = await native.commit(operation(base:first,date:'2026-12-03',text:'跨月'));
    expect((await native.load(topicId,month)).blocks, isEmpty);
    final december = await native.load(topicId,'2026-12');
    expect(december.blocks.single.blockId, first.blockId);
    expect(december.months, ['2026-12',month]);
    expect(moved.parentRevisionId, first.revisionId);
    expect((await db.customSelect('SELECT COUNT(*) AS n FROM mod_month_revisions').getSingle()).read<int>('n'), 2);
  });

  test('summary tombstone restores the same identity and does not allow a second summary', () async {
    final summary = await native.commit(operation(summary:true));
    final deleted = await native.commit(ModMonthMutation.fromBlock(summary,
      operationId:'native-delete-summary',revisionId:'native-summary-tombstone',deleted:true));
    await expectLater(native.commit(operation(summary:true)),throwsA(isA<ModMonthStoreException>()));
    final restored = await native.commit(ModMonthMutation.fromBlock(deleted,
      operationId:'native-restore-summary',revisionId:'native-summary-restored',deleted:false));
    expect(restored.blockId, summary.blockId);
    expect(restored.deleted, false);
    expect((await native.load(topicId,month)).blocks.length,1);
  });

  test('delete/restore retains exact event and body and never changes legacy Diaries', () async {
    final first = await native.commit(operation());
    final deleted = await native.commit(ModMonthMutation.fromBlock(first,
      operationId:'native-delete-entry',revisionId:'native-entry-tombstone',deleted:true));
    final restored = await native.commit(ModMonthMutation.fromBlock(deleted,
      operationId:'native-restore-entry',revisionId:'native-entry-restored',deleted:false));
    expect(restored.occurredAtMs,first.occurredAtMs);
    expect(restored.dayKey,first.dayKey);
    expect(restored.tiptapJson,first.tiptapJson);
    expect(await diaries.getDiaryByBusinessId(topicId),topic);
  });

  test('topic deletion between load and save refuses writes without orphan blocks', () async {
    await native.load(topicId,month);
    await diaries.updateADiary(newDiary: topic.copyWith(show:false), index: IndexMode.skip);
    await expectLater(native.commit(operation()),throwsA(isA<ModMonthStoreException>()
      .having((e)=>e.code,'code','topic_not_available')));
    expect((await db.customSelect('SELECT COUNT(*) AS n FROM mod_month_blocks').getSingle()).read<int>('n'),0);
  });

  test('ordinary Diary cannot become a native long-term topic by passing its ID', () async {
    await diaries.updateADiary(newDiary: topic.copyWith(tags:[]), index:IndexMode.skip);
    await expectLater(native.load(topicId,month),throwsA(isA<ModMonthStoreException>()));
    await expectLater(native.commit(operation()),throwsA(isA<ModMonthStoreException>()));
  });

  test('unsupported persisted document is not silently flattened or repaired', () async {
    await native.commit(operation());
    await db.customStatement("UPDATE mod_month_revisions SET body_json = '{\"type\":\"doc\",\"attrs\":{\"v\":99}}'");
    await expectLater(native.load(topicId,month),throwsA(isA<Exception>()));
    final row = await db.customSelect('SELECT body_json FROM mod_month_revisions').getSingle();
    expect(row.read<String>('body_json'), contains('99'));
  });

  test('notification failure after commit remains a successful save', () async {
    final repository = ModNativeMonthRepository(store:native.store,diaries:diaries,
      onCommitted:(_) => throw StateError('closed subscriber'));
    final saved = await repository.commit(operation());
    expect((await native.load(topicId,month)).blocks.single.revisionId,saved.revisionId);
  });

  test('out-of-range persisted timestamp fails the snapshot before native rendering', () async {
    await native.commit(operation());
    await db.customStatement('UPDATE mod_month_revisions SET occurred_at_ms = 9223372036854775807');
    await expectLater(native.load(topicId,month),throwsA(isA<ModMonthStoreException>()
      .having((e)=>e.code,'code','invalid_event_time')));
    expect((await db.customSelect('SELECT COUNT(*) AS n FROM mod_month_revisions').getSingle()).read<int>('n'),1);
  });

  test('invalid archive date is rejected instead of normalizing across a month boundary', () async {
    await native.commit(operation());
    await db.customStatement("UPDATE mod_month_revisions SET day_key = '2026-11-31'");
    await expectLater(native.load(topicId,month),throwsA(isA<ModMonthStoreException>()
      .having((e)=>e.code,'code','invalid_record_day')));
  });

  test('real HTTP and native adapters share heads and cross-device stale-parent protection', () async {
    final first = await native.commit(operation());
    final handler = ModLanMonthHttp(store:native.store,repository:diaries);
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4,0);
    final client = HttpClient();
    final authority = '127.0.0.1:${server.port}';
    server.listen((r) async => handler.tryHandle(r,authority:authority,
      csrfToken:'test-csrf',isSessionActive:()=>true));
    try {
      Future<({int status,Map<String,dynamic> body})> send({ModMonthMutation? mutation}) async {
        final request = await client.openUrl(mutation == null ? 'GET':'POST',
          Uri.parse('http://$authority/api/v3/months/$topicId/$month${mutation==null?'':'/revisions'}'));
        request.headers.set('origin','http://$authority');
        request.headers.set('x-moodiary-csrf','test-csrf');
        if(mutation != null) {
          final json = mutation.toJson()..remove('schemaVersion')..remove('topicId')..remove('monthKey');
          request.headers.contentType = ContentType.json;
          request.write(jsonEncode(json));
        }
        final response = await request.close();
        final json = jsonDecode(await utf8.decoder.bind(response).join()) as Map<String,dynamic>;
        return(status:response.statusCode,body:json);
      }
      final read = await send();
      expect(read.status,200);
      expect((read.body['blocks'] as List).single['revisionId'],first.revisionId);
      final pc = operation(base:first,text:'来自 PC 的新版本');
      expect((await send(mutation:pc)).status,200);
      expect((await native.load(topicId,month)).blocks.single.revisionId,pc.revisionId);
      await expectLater(native.commit(operation(base:first,text:'过期手机草稿')),
        throwsA(isA<ModMonthStoreException>()));
      final latest = (await native.load(topicId,month)).blocks.single;
      await native.commit(operation(base:latest,text:'来自手机的后续版本'));
      expect((await send(mutation:operation(base:latest,text:'过期 PC 草稿'))).status,409);
    } finally {
      client.close(force:true);
      await server.close(force:true);
    }
  });
}
