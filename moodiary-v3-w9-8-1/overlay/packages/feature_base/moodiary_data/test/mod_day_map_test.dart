import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moodiary_data/moodiary_data.dart';

const topic = 'topic-2026-learning';
const other = 'another-topic';
const month = '2026-11';
const day = '2026-11-07';

void main() {
  late MoodiaryDatabase db;
  late ModDayMap map;

  setUp(() async {
    db = MoodiaryDatabase.forTesting(NativeDatabase.memory());
    await db.customSelect('SELECT 1').get();
    map = ModDayMap(db, now: () => DateTime.utc(2026, 11, 8));
  });
  tearDown(() async { await db.close(); });

  Future<void> seed({String topicId = topic, String kind = 'entry',
    bool deleted = false, String date = day, String suffix = 'alpha'}) async {
    await db.customStatement(
      'INSERT OR IGNORE INTO mod_month_pages'
      '(topic_id,month_key,diary_id,created_ms) VALUES(?,?,NULL,?)',
      [topicId,month,10],
    );
    final block = 'block-$suffix-$topicId';
    final revision = 'revision-$suffix-$topicId';
    await db.customStatement(
      'INSERT INTO mod_month_blocks'
      '(block_id,topic_id,month_key,kind,created_ms) VALUES(?,?,?,?,?)',
      [block,topicId,month,kind,20],
    );
    await db.customStatement(
      'INSERT INTO mod_month_revisions'
      '(revision_id,block_id,parent_revision_id,month_key,day_key,'
      'occurred_at_ms,body_json,deleted,edited_at_ms)'
      ' VALUES(?,?,NULL,?,?,?,?,?,?)',
      [revision,block,month,kind=='summary'?null:date,30,
       '{"type":"doc","attrs":{"v":2},"content":[]}',deleted?1:0,40],
    );
    await db.customStatement(
      'INSERT INTO mod_month_heads(block_id,revision_id) VALUES(?,?)',
      [block,revision],
    );
  }

  test('fresh schema v5, zero normal diaries and no implicit day page', () async {
    expect(db.schemaVersion, 5);
    expect(await map.readTopic(topic), isEmpty);
    expect((await db.customSelect('SELECT COUNT(*) AS n FROM diaries')
        .getSingle()).read<int>('n'), 0);
  });

  test('one topic and natural day maps to one durable row, no Diary writes', () async {
    await seed();
    final first = await map.ensureFromLiveBlock(topicId:topic,dayKey:day);
    expect(first.diaryId, isNull);
    expect(first.visibleLocal, true);
    expect(first.createdMs, DateTime.utc(2026,11,8).millisecondsSinceEpoch);
    final duplicate = await ModDayMap(db).ensureFromLiveBlock(
      topicId:topic,dayKey:day);
    expect(duplicate.createdMs, first.createdMs);
    expect(await map.readTopic(topic), hasLength(1));
    expect((await db.customSelect('SELECT COUNT(*) AS n FROM diaries')
        .getSingle()).read<int>('n'), 0);
  });

  test('same day across different topics stays isolated', () async {
    await seed();
    await seed(topicId:other);
    await map.ensureFromLiveBlock(topicId:topic,dayKey:day);
    await map.ensureFromLiveBlock(topicId:other,dayKey:day);
    expect((await map.readTopic(topic)).single.topicId, topic);
    expect((await map.readTopic(other)).single.topicId, other);
  });

  test('local visibility persists without changing ordinary Diary rows', () async {
    await seed();
    await map.ensureFromLiveBlock(topicId:topic,dayKey:day);
    final hidden = await map.setLocalVisibility(
      topicId:topic,dayKey:day,visible:false);
    expect(hidden.visibleLocal, false);
    final again = await ModDayMap(db).readDay(topicId:topic,dayKey:day);
    expect(again!.visibleLocal, false);
    expect((await db.customSelect('SELECT COUNT(*) AS n FROM diaries')
        .getSingle()).read<int>('n'),0);
    final shown=await map.setLocalVisibility(
      topicId:topic,dayKey:day,visible:true);
    expect(shown.visibleLocal,true);
  });

  test('invalid calendar date and empty/summary/deleted day cannot create mapping', () async {
    await expectLater(map.ensureFromLiveBlock(
      topicId:topic,dayKey:'2026-11-31'),throwsA(isA<ModDayMapException>()));
    await expectLater(map.ensureFromLiveBlock(
      topicId:topic,dayKey:day),throwsA(isA<ModDayMapException>()));
    await seed(kind:'summary');
    await expectLater(map.ensureFromLiveBlock(
      topicId:topic,dayKey:day),throwsA(isA<ModDayMapException>()));
    await seed(kind:'entry',deleted:true,suffix:'deleted');
    await expectLater(map.ensureFromLiveBlock(
      topicId:topic,dayKey:day),throwsA(isA<ModDayMapException>()));
    expect(await map.readTopic(topic), isEmpty);
  });

  test('a conflicted head cannot authorize a materialized day', () async {
    await seed();
    await db.customStatement(
      'INSERT INTO mod_month_revisions'
      '(revision_id,block_id,parent_revision_id,month_key,day_key,'
      'occurred_at_ms,body_json,deleted,edited_at_ms)'
      ' VALUES(?,?,NULL,?,?,?,?,?,?)',
      ['revision-beta-$topic','block-alpha-$topic',month,day,31,
       '{"type":"doc"}',0,41],
    );
    await db.customStatement(
      'INSERT INTO mod_month_heads(block_id,revision_id) VALUES(?,?)',
      ['block-alpha-$topic','revision-beta-$topic'],
    );
    await expectLater(map.ensureFromLiveBlock(topicId:topic,dayKey:day),
      throwsA(isA<ModDayMapException>().having((e)=>e.code,
        'code','conflicting_daily_block_heads')));
    expect(await map.readTopic(topic), isEmpty);
  });

  test('new day metadata explicitly blocks incomplete legacy and W9 graph export', () async {
    await seed();
    await map.ensureFromLiveBlock(topicId:topic,dayKey:day);
    await expectLater(ModMonthArchiveGate.requireLegacyOnly(db),
      throwsA(isA<ModMonthArchiveBlocked>()));
    await expectLater(ModMonthGraphArchiveV1.exportGraph(db),
      throwsA(isA<ModGraphArchiveException>()));
    expect(await map.readTopic(topic), hasLength(1));
  });

  test('clearAll clears day mapping as well as W9 month blocks', () async {
    await seed();
    await map.ensureFromLiveBlock(topicId:topic,dayKey:day);
    await db.clearAll();
    expect(await map.readTopic(topic),isEmpty);
    expect((await db.customSelect('SELECT COUNT(*) AS n FROM mod_month_blocks')
        .getSingle()).read<int>('n'),0);
  });
}
