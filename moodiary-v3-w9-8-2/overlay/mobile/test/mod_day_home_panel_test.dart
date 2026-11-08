import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moodiary_data/moodiary_data.dart';
import 'package:moodiary_mobile/app/home/mod_day_home_index.dart';
import 'package:moodiary_mobile/app/home/mod_day_home_panel.dart';
import 'package:moodiary_mobile/app/home/mod_month_store.dart';
import 'package:moodiary_mobile/app/home/mod_month_updates.dart';

const topic = 'topic-training-2026';
const day = '2026-11-07';

String doc(String t) => jsonEncode({
  'type':'doc','attrs':{'v':2},
  'content':[{'type':'paragraph',
    'content':[{'type':'text','text':t}]}],
});

void main() {
  late MoodiaryDatabase db;
  late ModMonthStore store;
  late ModDailyHomeIndex index;
  var opened = <String>[];

  setUp(() async {
    db = MoodiaryDatabase.forTesting(NativeDatabase.memory());
    await db.customSelect('SELECT 1').get();
    store = ModMonthStore(db,clock:()=>DateTime.utc(2026,11,8,12));
    index = ModDailyHomeIndex(
      store:store,dayMap:ModDayMap(db),
      topicTitle:(id) async => id==topic ? '学习主题' : null,
    );
    opened=<String>[];
    await store.appendRevision(
      operationId:'operation-created-01',
      blockId:'block-created-0001',
      revisionId:'revision-created-01',
      topicId:topic,monthKey:'2026-11',kind:'entry',
      parentRevisionId:null,dayKey:day,occurredAtMs:10,
      tiptapJson:doc('今天复习光刻机 Alignment'),
    );
  });
  tearDown(() async { await db.close(); });

  Widget app() => MaterialApp(home: Scaffold(body: Column(children:[
    ModDayHomePanel(repository:index,
      openDay:(_,value) async => opened.add(value.dayKey)),
    const Expanded(child: SizedBox()),
  ])));

  testWidgets('card is visible on home, and opens only the dedicated day', (tester) async {
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    expect(find.text('学习主题'),findsOneWidget);
    expect(find.textContaining(day),findsOneWidget);
    expect(find.textContaining('今天复习光刻机 Alignment'),findsOneWidget);
    await tester.tap(find.text('打开当天记录'));
    await tester.pumpAndSettle();
    expect(opened,[day]);
    expect((await db.customSelect('SELECT COUNT(*) AS n FROM diaries')
      .getSingle()).read<int>('n'),0);
  });

  testWidgets('hiding is local and reversible; a reload preserves choice', (tester) async {
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('从首页隐藏'));
    await tester.pumpAndSettle();
    expect(find.text('学习主题'),findsNothing);
    expect(find.byTooltip('显示已隐藏'),findsOneWidget);
    await tester.tap(find.byTooltip('显示已隐藏'));
    await tester.pumpAndSettle();
    expect(find.text('学习主题'),findsOneWidget);
    await tester.tap(find.byTooltip('在首页显示'));
    await tester.pumpAndSettle();
    expect((await ModDayMap(db).readTopic(topic)).single.visibleLocal,true);
  });

  testWidgets('bad snapshot disables cards rather than opening stale content', (tester) async {
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    await db.customStatement(
      'INSERT INTO mod_month_revisions'
      '(revision_id,block_id,parent_revision_id,month_key,day_key,'
      'occurred_at_ms,body_json,deleted,edited_at_ms)'
      ' VALUES(?,?,NULL,?,?,?,?,?,?)',
      ['revision-concurrent-1','block-created-0001',
        '2026-11',day,20,doc('conflict'),0,20],
    );
    await db.customStatement(
      'INSERT INTO mod_month_heads(block_id,revision_id) VALUES(?,?)',
      ['block-created-0001','revision-concurrent-1'],
    );
    ModMonthUpdates.publish(topic);
    await tester.pumpAndSettle();
    expect(find.textContaining('每日记录读取异常'),findsOneWidget);
    expect(find.text('学习主题'),findsNothing);
    expect(opened,isEmpty);
  });

  testWidgets('320-pixel screen and keyboard inset do not overflow', (tester) async {
    tester.view.physicalSize=const Size(320,640);
    tester.view.devicePixelRatio=1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    expect(tester.takeException(),isNull);
  });
}
