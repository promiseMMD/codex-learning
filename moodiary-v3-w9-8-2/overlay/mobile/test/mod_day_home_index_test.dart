import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moodiary_data/moodiary_data.dart';
import 'package:moodiary_mobile/app/home/mod_day_home_index.dart';
import 'package:moodiary_mobile/app/home/mod_month_store.dart';

const topicA = 'topic-study-2026';
const topicB = 'topic-travel-2026';
const day1 = '2026-11-07';
const day2 = '2026-11-08';

String document(String value) => jsonEncode({
  'type':'doc','attrs':{'v':2},
  'content':[{'type':'paragraph','content':[{'type':'text','text':value}]}],
});

void main() {
  late MoodiaryDatabase db;
  late ModMonthStore store;
  late ModDayMap dayMap;
  late ModDailyHomeIndex index;
  final titles = <String,String?>{
    topicA:'学习记录',topicB:'旅行记录',
  };

  setUp(() async {
    db = MoodiaryDatabase.forTesting(NativeDatabase.memory());
    await db.customSelect('SELECT 1').get();
    store = ModMonthStore(db, clock: () => DateTime.utc(2026,11,8,12));
    dayMap = ModDayMap(db);
    index = ModDailyHomeIndex(
      store: store, dayMap: dayMap,
      topicTitle:(id) async => titles[id],
    );
  });
  tearDown(() async { await db.close(); });

  Future<void> append(String topic, String id, String day, int time, {
    bool deleted = false,
    String? parent,
    String? text,
  }) async {
    await store.appendRevision(
      operationId:'operation-' + id + (parent == null ? '' : '-edit'),
      blockId: id,
      revisionId:'revision-' + id + (parent == null ? '' : '-edit'),
      topicId:topic,monthKey:'2026-11',kind:'entry',
      parentRevisionId: parent,
      dayKey:day,occurredAtMs:time,
      tiptapJson:document(text ?? id),
      deleted:deleted,
    );
  }

  test('home list is read-only; a day receives last three entries in order', () async {
    await append(topicA,'block-morning-001',day1,100);
    await append(topicA,'block-noon-00002',day1,200);
    await append(topicA,'block-evening-03',day1,300);
    await append(topicA,'block-night-0004',day1,400);
    await append(topicB,'block-travel-001',day2,500);
    final days = await index.load();
    expect(days.map((d) => d.dayKey),[day2,day1]);
    expect(days.last.topicTitle,'学习记录');
    expect(days.last.count,4);
    expect(days.last.preview,'block-noon-00002 · block-evening-03 · block-night-0004');
    expect(days.last.visibleLocal,true);
    expect((await db.customSelect('SELECT COUNT(*) AS n FROM mod_day_pages')
      .getSingle()).read<int>('n'),0);
    expect((await db.customSelect('SELECT COUNT(*) AS n FROM diaries')
      .getSingle()).read<int>('n'),0);
  });

  test('local hide survives a fresh read and can be undone without Diary edits', () async {
    await append(topicA,'block-first-0001',day1,300);
    final visible = (await index.load()).single;
    await index.setVisible(visible,false);
    final hidden = (await index.load()).single;
    expect(hidden.visibleLocal,false);
    expect(hidden.count,1);
    await index.setVisible(hidden,true);
    expect((await index.load()).single.visibleLocal,true);
    expect((await dayMap.readTopic(topicA)).single.diaryId,isNull);
    expect((await db.customSelect('SELECT COUNT(*) AS n FROM diaries')
      .getSingle()).read<int>('n'),0);
  });

  test('deleted current heads, unknown topics and empty days create no cards', () async {
    await append(topicA,'block-deleted-01',day1,100,deleted:true);
    await append('topic-not-shown','block-unknown-01',day2,200);
    expect(await index.load(),isEmpty);
    expect(await dayMap.readTopic(topicA),isEmpty);
  });

  test('missing or multi-head current revision is not turned into a daily card', () async {
    await append(topicA,'block-conflict-1',day1,100);
    await db.customStatement(
      'INSERT INTO mod_month_revisions'
      '(revision_id,block_id,parent_revision_id,month_key,day_key,'
      'occurred_at_ms,body_json,deleted,edited_at_ms)'
      ' VALUES(?,?,NULL,?,?,?,?,?,?)',
      ['rev-other-head','block-conflict-1','2026-11',day1,101,
       document('concurrent'),0,102],
    );
    await db.customStatement(
      'INSERT INTO mod_month_heads(block_id,revision_id) VALUES(?,?)',
      ['block-conflict-1','rev-other-head'],
    );
    await expectLater(index.load(),throwsA(isA<ModMonthStoreException>()));
    expect(await dayMap.readTopic(topicA),isEmpty);
  });

  test('a future native binding cannot accidentally open the ordinary editor', () async {
    await append(topicA,'block-today-001',day1,100);
    final day=(await index.load()).single;
    await index.setVisible(day,true);
    await db.customStatement(
      'INSERT INTO diaries'
      '(id,title,content,content_text,time,last_modified,show,type)'
      ' VALUES(?,?,?,?,?,?,?,?)',
      ['native-day-001','Do not overwrite','original','original',1,2,1,'tiptap'],
    );
    await db.customStatement(
      'UPDATE mod_day_pages SET diary_id=? WHERE topic_id=? AND day_key=?',
      ['native-day-001',topicA,day1],
    );
    await expectLater(index.load(),throwsStateError);
  });
}
