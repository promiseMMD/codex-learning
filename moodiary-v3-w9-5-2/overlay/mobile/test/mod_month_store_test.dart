import 'package:drift/drift.dart' show Variable;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moodiary_data/moodiary_data.dart';
import 'package:moodiary_di/moodiary_di.dart';
import 'package:moodiary_mobile/app/home/mod_month_store.dart';
import 'package:moodiary_mobile/app/home/mod_lan_rich.dart';
import 'package:moodiary_storage/moodiary_storage.dart';
import 'package:moodiary_storage/testing.dart';

const topic = 'topic-2026-learning';
const month = '2026-11';
const blockA = 'block-november-alpha';
const blockB = 'block-november-bravo';
const summary = 'block-november-summary';

String doc(String text) =>
    '{"type":"doc","attrs":{"v":2},"content":[{"type":"paragraph",'
    '"content":[{"type":"text","text":"$text"}]}]}';

void main() {
  setUpAll(() => getIt.registerSingleton<IKVStorage>(MemoryKVStorage()));

  group('W9 durable month store on native Moodiary SQLite', () {
    late MoodiaryDatabase db;
    late ModMonthStore store;

    setUp(() {
      db = MoodiaryDatabase.forTesting(NativeDatabase.memory());
      store = ModMonthStore(db, clock: () => DateTime.utc(2026, 11, 7));
    });
    tearDown(() async => db.close());

    Future<ModStoredBlock> create({
      String id = blockA,
      String operation = 'op-2026-create-alpha',
      String revision = 'rev-2026-create-alpha',
      String targetMonth = month,
      String date = '2026-11-07',
      String kind = 'entry',
      String? parent,
      String text = 'first',
      bool deleted = false,
      int occurredAtMs = 12345,
    }) => store.appendRevision(
      operationId: operation,
      blockId: id,
      revisionId: revision,
      topicId: topic,
      monthKey: targetMonth,
      kind: kind,
      parentRevisionId: parent,
      dayKey: kind == 'summary' ? null : date,
      occurredAtMs: occurredAtMs,
      tiptapJson: doc(text),
      deleted: deleted,
    );

    test('schema v4 is ready on fresh DB without touching legacy Diaries', () async {
      expect(db.schemaVersion, 4);
      final p = await store.ensureMonth(topicId: topic, monthKey: month);
      expect(p.diaryId, isNull);
      await store.ensureMonth(topicId: topic, monthKey: month);
      final rows = await db.customSelect(
        'SELECT COUNT(*) AS n FROM mod_month_pages',
      ).get();
      expect(rows.single.read<int>('n'), 1);
      final oldDiaries = await db.customSelect(
        'SELECT COUNT(*) AS n FROM diaries',
      ).get();
      expect(oldDiaries.single.read<int>('n'), 0);
    });

    test('two independent blocks and one unique collapsed-view summary', () async {
      await create(occurredAtMs: 20000);
      await create(id: blockB, operation: 'op-create-bravo',
          revision: 'rev-create-bravo', date: '2026-11-08',
          occurredAtMs: 10000, text: 'second');
      await create(id: summary, operation: 'op-create-summary',
          revision: 'rev-create-summary', kind: 'summary',
          occurredAtMs: 30000, text: 'November summary');

      final list = await store.readMonth(topicId: topic, monthKey: month);
      expect(list.length, 3);
      expect(list.map((e) => e.blockId).toList(), [blockB, blockA, summary]);
      final s = await store.readSummary(topicId: topic, monthKey: month);
      expect(s?.kind, 'summary');
      expect(s?.dayKey, isNull);
      await expectLater(
        create(id: 'block-another-summary', operation: 'op-extra-summary',
          revision: 'rev-extra-summary', kind: 'summary'),
        throwsA(isA<Exception>()),
      );
      expect((await store.readMonth(topicId: topic, monthKey: month)).length, 3);
    });

    test('request replay is idempotent and reused operation with different body rejects', () async {
      final first = await create();
      final duplicate = await create();
      expect(duplicate.revisionId, first.revisionId);
      expect((await store.readMonth(topicId:topic, monthKey:month)).length, 1);
      final opCount = await db.customSelect(
        'SELECT COUNT(*) AS n FROM mod_month_ops',
      ).get();
      expect(opCount.single.read<int>('n'), 1);
      await expectLater(
        create(text: 'different'),
        throwsA(isA<ModMonthStoreException>().having(
          (e) => e.code,'code','operation_id_collision')),
      );
      expect((await store.readMonth(topicId: topic, monthKey: month))
          .single.tiptapJson, doc('first'));
    });

    test('CAS edit rejects stale revision and retains winner', () async {
      final first = await create();
      final next = await create(
        operation: 'op-edit-alpha',
        revision: 'rev-edit-alpha',
        parent: first.revisionId,
        text: 'winner',
      );
      expect(next.parentRevisionId, first.revisionId);
      await expectLater(
        create(
          operation: 'op-concurrent-alpha',
          revision: 'rev-concurrent-alpha',
          parent: first.revisionId,
          text: 'should-not-overwrite',
        ),
        throwsA(isA<ModMonthStoreException>().having(
          (e) => e.code,'code','stale_revision')),
      );
      expect((await store.readMonth(topicId: topic, monthKey: month))
          .single.tiptapJson, doc('winner'));
    });

    test('deleted block remains as tombstone and can be restored by revision', () async {
      final first = await create();
      final deleted = await create(
        operation:'op-delete-alpha', revision:'rev-delete-alpha',
        parent:first.revisionId, deleted:true,
      );
      expect(deleted.deleted, true);
      expect(await store.readMonth(topicId:topic,monthKey:month), isEmpty);
      expect((await store.readMonth(topicId:topic,monthKey:month,
        includeDeleted:true)).single.deleted, true);
      await create(
        operation:'op-restore-alpha',revision:'rev-restore-alpha',
        parent:deleted.revisionId, text:'restored',
      );
      expect((await store.readMonth(topicId:topic,monthKey:month))
          .single.tiptapJson, doc('restored'));
    });

    test('cross-month move retains block identity and complete history', () async {
      final first = await create();
      final moved = await create(
        operation:'op-move-alpha',revision:'rev-move-alpha',
        parent:first.revisionId,targetMonth:'2026-12',
        date:'2026-12-03',text:'moved-content',
      );
      expect(moved.blockId, first.blockId);
      expect(moved.monthKey, '2026-12');
      expect(await store.readMonth(topicId:topic,monthKey:month), isEmpty);
      expect((await store.readMonth(topicId:topic,monthKey:'2026-12')).length, 1);
      final history = await db.customSelect(
        'SELECT revision_id FROM mod_month_revisions WHERE block_id = ?',
        variables: [Variable.withString(blockA)],
      ).get();
      expect(history.map((r) => r.read<String>('revision_id')).toSet(),
          {'rev-2026-create-alpha','rev-move-alpha'});
    });

    test('rejects invalid date and unsupported rich document before writing', () async {
      await expectLater(
        create(date:'2026-11-31'),
        throwsA(isA<ModMonthStoreException>().having(
          (e) => e.code,'code','invalid_record_day')),
      );
      await expectLater(
        store.appendRevision(
          operationId:'op-bad-rich-json',blockId:blockA,
          revisionId:'rev-bad-rich-json',topicId:topic,monthKey:month,
          kind:'entry',parentRevisionId:null,dayKey:'2026-11-07',
          occurredAtMs:1,
          tiptapJson:'{"type":"doc","attrs":{"v":3},"content":[]}',
        ),
        throwsA(isA<ModMonthStoreException>().having(
          (e) => e.code,'code','unsupported_block_document')),
      );
      expect(await store.readMonth(topicId:topic,monthKey:month),isEmpty);
    });

    test('month can bind only one existing diary; no regular diary mutations', () async {
      const native = '2a84fd42-c07e-4de8-9f0f-3ef9c99922fa';
      const second = '8a84fd42-c07e-4de8-9f0f-3ef9c99922fb';
      final writer=ModLanRichWriter(DiaryRepository(db));
      await writer.create({
        'id':native,'title':'untouched-existing-diary',
        'document':{
          'type':'doc','attrs':{'v':2},
          'content':[{'type':'paragraph','content':[
            {'type':'text','text':'legacy contents'}
          ]}],
        },
      });
      await store.bindExistingDiary(topicId:topic,monthKey:month,diaryId:native);
      await store.bindExistingDiary(topicId:topic,monthKey:month,diaryId:native);
      await expectLater(
        store.bindExistingDiary(topicId:topic,monthKey:'2026-12',diaryId:native),
        throwsA(isA<ModMonthStoreException>().having(
          (e)=>e.code,'code','diary_already_bound')),
      );
      await expectLater(
        store.bindExistingDiary(topicId:topic,monthKey:month,diaryId:second),
        throwsA(isA<ModMonthStoreException>().having(
          (e)=>e.code,'code','native_diary_not_found')),
      );
      expect((await writer.load(native)).title,'untouched-existing-diary');
      final pages = await db.customSelect(
        'SELECT topic_id,month_key,diary_id FROM mod_month_pages'
        ' WHERE diary_id IS NOT NULL',
      ).get();
      expect(pages.length,1);
      expect(pages.single.read<String>('diary_id'),native);
    });

    test('a second store instance sees durable revisions, not in-memory state', () async {
      await create();
      final second = ModMonthStore(db);
      final read = await second.readMonth(topicId:topic,monthKey:month);
      expect(read.length,1);
      expect(read.single.blockId,blockA);
    });

    test('original block creation time survives edits/retries and sorts equal events', () async {
      var time=DateTime.utc(2026,11,7,8);
      store=ModMonthStore(db,clock:()=>time);
      final first=await create(id:blockB,operation:'operation-created-first',revision:'revision-created-first',occurredAtMs:5000);
      time=time.add(const Duration(seconds:1));
      await create(id:blockA,operation:'operation-created-second',revision:'revision-created-second',occurredAtMs:5000);
      var rows=await store.readMonth(topicId:topic,monthKey:month);
      expect(rows.map((b)=>b.blockId),[blockB,blockA]);
      expect(first.createdAtMs,DateTime.utc(2026,11,7,8).millisecondsSinceEpoch);
      time=time.add(const Duration(seconds:1));
      final edited=await create(id:blockB,operation:'operation-created-edit',revision:'revision-created-edit',parent:first.revisionId,occurredAtMs:5000,text:'later edit');
      expect(edited.createdAtMs,first.createdAtMs);
      expect(edited.editedAtMs,greaterThan(edited.createdAtMs));
      rows=await store.readMonth(topicId:topic,monthKey:month);
      expect(rows.map((b)=>b.blockId),[blockB,blockA]);
    });

    test('whole-app reset also clears custom v4 tables', () async {
      await create();
      await db.clearAll();
      final v = await db.customSelect(
        'SELECT COUNT(*) AS n FROM mod_month_blocks',
      ).get();
      expect(v.single.read<int>('n'),0);
    });
  });
}
