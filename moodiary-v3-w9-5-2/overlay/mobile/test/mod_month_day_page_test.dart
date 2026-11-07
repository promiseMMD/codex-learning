import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moodiary_data/moodiary_data.dart';
import 'package:moodiary_di/moodiary_di.dart';
import 'package:moodiary_editor/moodiary_editor.dart';
import 'package:moodiary_i18n/moodiary_i18n.dart';
import 'package:moodiary_mobile/app/home/mod_continuous.dart';
import 'package:moodiary_mobile/app/home/mod_month_composer.dart';
import 'package:moodiary_mobile/app/home/mod_month_native.dart';
import 'package:moodiary_mobile/app/home/mod_month_page.dart';
import 'package:moodiary_mobile/app/home/mod_month_store.dart';
import 'package:moodiary_models/moodiary_models.dart';
import 'package:moodiary_storage/moodiary_storage.dart';
import 'package:moodiary_storage/testing.dart';
import 'package:mui/mui.dart';

const topic='aac26e25-4a1d-4b4c-b256-9b0c347d36e2';
const selectedDay='2026-11-01';
String doc(String text)=>jsonEncode({'type':'doc','attrs':{'v':2},'content':[
  {'type':'paragraph','content':[{'type':'text','text':text}]}]});
ModStoredBlock block(String id,String text,{String day=selectedDay,
  bool deleted=false,String kind='entry',int created=100})=>ModStoredBlock(
  blockId:id,revisionId:'revision-$id',parentRevisionId:null,topicId:topic,
  monthKey:'2026-11',kind:kind,dayKey:kind=='summary'?null:day,
  occurredAtMs:1794038400000,createdAtMs:created,editedAtMs:1794038400000,
  tiptapJson:doc(text),deleted:deleted);

class _Editor extends MoodiaryEditorController{
  @override Future<void> blur()async{}
  @override Future<String> snapshot()async=>doc('saved to selected day');
}
class _Repository extends ModNativeMonthRepository{
  final blocks=<String,ModStoredBlock>{};
  final attempts=<ModMonthMutation>[];
  bool failReads=false;
  bool loseAcknowledgement=false;
  int reads=0;
  _Repository(ModMonthStore store,DiaryRepository diaries):super(store:store,diaries:diaries){
    for(final b in [block('z-first-created','selected first',created:100),
      block('a-later-created','selected second',created:200),
      block('other-day-block','another day',day:'2026-11-08'),
      block('deleted-block','deleted text',deleted:true),
      block('monthly-summary','summary body',kind:'summary')]){blocks[b.blockId]=b;}
  }
  @override Future<ModNativeMonthSnapshot> load(String id,String month)async{
    reads++;
    if(failReads)throw StateError('read failed');
    return ModNativeMonthSnapshot(topic:Diary.create(title:'Native topic',
      content:doc('topic'),contentText:'topic',imageName:[],audioName:[],videoName:[],
      tags:[ModDiary.topicTag],type:DiaryType.tiptap).copyWith(id:topic),
      monthKey:month,months:[month],legacyCount:0,
      blocks:blocks.values.where((b)=>b.monthKey==month));
  }
  @override Future<ModStoredBlock> commit(ModMonthMutation op)async{
    attempts.add(op);
    final saved=blocks[op.blockId]??ModStoredBlock(blockId:op.blockId,
      revisionId:op.revisionId,parentRevisionId:op.parentRevisionId,topicId:topic,
      monthKey:op.monthKey,kind:op.kind,dayKey:op.dayKey,
      occurredAtMs:op.occurredAtMs,createdAtMs:1794038500000,
      editedAtMs:1794038500000,tiptapJson:op.tiptapJson,deleted:op.deleted);
    blocks[op.blockId]=saved;
    if(loseAcknowledgement)throw StateError('saved but acknowledgement lost');
    return saved;
  }
}

void main(){
  late MoodiaryDatabase db;
  late _Repository repository;
  late _Editor editor;
  setUp((){
    getIt.registerSingleton<IKVStorage>(MemoryKVStorage());
    db=MoodiaryDatabase.forTesting(NativeDatabase.memory());
    repository=_Repository(ModMonthStore(db),DiaryRepository(db));
    editor=_Editor();
  });
  tearDown(()async{await db.close();await getIt.reset();});
  Future<void> mount(WidgetTester tester,{String? day=selectedDay,bool keyboard=false})async{
    tester.view.physicalSize=const Size(390,844);
    tester.view.devicePixelRatio=1;
    if(keyboard)tester.view.viewInsets=const FakeViewPadding(bottom:320);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetViewInsets);
    await tester.pumpWidget(TranslationProvider(child:MaterialApp(
      theme:buildMuiTheme(brightness:.light),
      localizationsDelegates:const [...GlobalMaterialLocalizations.delegates,
        GlobalMuiLocalizations.delegate],
      builder:(context,child)=>MaterialUiCompatibilityBridge(child:child!),
      home:ModMonthPage(topicId:topic,repository:repository,openLegacy:()async{},
        dayKey:day,composerController:editor))));
    await tester.pumpAndSettle();
  }

  testWidgets('daily route isolates the selected day and uses original creation order',(tester)async{
    await mount(tester);
    expect(find.text(l10n.month.dayTitle(title:'Native topic',day:selectedDay)),findsOneWidget);
    expect(find.text(l10n.month.dayCount(count:2)),findsOneWidget);
    expect(find.text('another day'),findsNothing);
    expect(find.text('summary body'),findsNothing);
    expect(find.text('deleted text'),findsNothing);
    final first=tester.getTopLeft(find.byKey(const ValueKey('z-first-created'))).dy;
    final second=tester.getTopLeft(find.byKey(const ValueKey('a-later-created'))).dy;
    expect(first,lessThan(second));
    expect(find.byType(DropdownButton<String>),findsNothing);
  });

  testWidgets('month day header opens a separate daily route and Back preserves month view',(tester)async{
    await mount(tester,day:null);
    await tester.ensureVisible(find.text(l10n.month.openDay).first);
    await tester.tap(find.text(l10n.month.openDay).first);
    await tester.pumpAndSettle();
    expect(find.byType(DropdownButton<String>),findsNothing);
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.byType(DropdownButton<String>),findsOneWidget);
  });

  testWidgets('quick append saves to selected past date, closes sheet and stays on the day',(tester)async{
    await mount(tester,keyboard:true);
    await tester.tap(find.byType(FloatingActionButton));
    await tester.pumpAndSettle();
    expect(find.byType(ModMonthComposer),findsOneWidget);
    expect(tester.takeException(),isNull);
    await tester.tap(find.widgetWithText(FilledButton,l10n.common.save));
    await tester.pumpAndSettle();
    expect(find.byType(ModMonthComposer),findsNothing);
    expect(repository.attempts.single.dayKey,selectedDay);
    expect(repository.attempts.single.monthKey,'2026-11');
    expect(find.text(l10n.month.dayTitle(title:'Native topic',day:selectedDay)),findsOneWidget);
    expect(find.text(l10n.month.dayCount(count:3)),findsOneWidget);
    expect(tester.takeException(),isNull);
  });

  testWidgets('lost save acknowledgement retains the sheet and retries the identical operation',(tester)async{
    repository.loseAcknowledgement=true;
    await mount(tester);
    await tester.tap(find.byType(FloatingActionButton));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton,l10n.common.save));
    await tester.pumpAndSettle();
    expect(find.byType(ModMonthComposer),findsOneWidget);
    expect(find.text(l10n.month.uncertain),findsOneWidget);
    repository.loseAcknowledgement=false;
    await tester.tap(find.widgetWithText(FilledButton,l10n.month.retrySame));
    await tester.pumpAndSettle();
    expect(find.byType(ModMonthComposer),findsNothing);
    expect(repository.attempts.length,2);
    expect(identical(repository.attempts.first,repository.attempts.last),true);
    expect(repository.blocks.values.where((b)=>modBlockText(b.tiptapJson)=='saved to selected day').length,1);
  });

  testWidgets('invalid daily route is read-only and cannot load or create blocks',(tester)async{
    await mount(tester,day:'2026-11-31');
    expect(find.text(l10n.month.readOnly),findsOneWidget);
    expect(repository.reads,0);
    expect(tester.widget<FloatingActionButton>(find.byType(FloatingActionButton)).onPressed,isNull);
    expect(repository.attempts,isEmpty);
    expect(tester.takeException(),isNull);
  });
}
