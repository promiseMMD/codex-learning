import 'dart:async';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moodiary_data/moodiary_data.dart';
import 'package:moodiary_di/moodiary_di.dart';
import 'package:moodiary_i18n/moodiary_i18n.dart';
import 'package:moodiary_mobile/app/home/mod_continuous.dart';
import 'package:moodiary_mobile/app/home/mod_month_composer.dart';
import 'package:moodiary_mobile/app/home/mod_month_page.dart';
import 'package:moodiary_models/moodiary_models.dart';
import 'package:moodiary_storage/moodiary_storage.dart';
import 'package:moodiary_storage/testing.dart';
import 'package:mui/mui.dart';

class _Repository implements DiaryRepository{
  final events=StreamController<DiaryEvent>.broadcast();
  final topic=Diary.create(title:'Pinned topic',content:'',contentText:'',
    imageName:[],audioName:[],videoName:[],type:DiaryType.tiptap,
    tags:[ModDiary.topicTag,ModDiary.pinTag,'${ModDiary.rankPrefix}0']);
  @override Stream<DiaryEvent> get diaryEvents=>events.stream;
  @override Future<List<Diary>> getAllDiaries()async=>[topic];
  @override dynamic noSuchMethod(Invocation invocation)=>super.noSuchMethod(invocation);
}
void main(){
  late MoodiaryDatabase db;
  late _Repository repository;
  setUp((){
    getIt.registerSingleton<IKVStorage>(MemoryKVStorage());
    db=MoodiaryDatabase.forTesting(NativeDatabase.memory());
    repository=_Repository();
    getIt.registerSingleton<MoodiaryDatabase>(db);
    getIt.registerSingleton<DiaryRepository>(repository);
  });
  tearDown(()async{await repository.events.close();await db.close();await getIt.reset();});
  testWidgets('home plus opens one protected sheet without pushing a topic page',(tester)async{
    tester.view.physicalSize=const Size(390,844);
    tester.view.devicePixelRatio=1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(TranslationProvider(child:MaterialApp(
      theme:buildMuiTheme(brightness:.light),
      localizationsDelegates:const [...GlobalMaterialLocalizations.delegates,
        GlobalMuiLocalizations.delegate],
      builder:(context,child)=>MaterialUiCompatibilityBridge(child:child!),
      home:const Scaffold(body:Column(children:[Text('Original home'),ModPinnedStrip()])))));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('追加记录'));
    await tester.pumpAndSettle();
    expect(find.byType(ModMonthComposer),findsOneWidget);
    expect(find.byType(ModTopicPage),findsNothing);
    expect(find.byType(ModMonthPage),findsNothing);
    await tester.tapAt(const Offset(5,5));
    await tester.pumpAndSettle();
    expect(find.byType(ModMonthComposer),findsOneWidget);
    await tester.tap(find.byTooltip(l10n.common.close));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton,l10n.month.discard));
    await tester.pumpAndSettle();
    expect(find.byType(ModMonthComposer),findsNothing);
    expect(find.text('Original home'),findsOneWidget);
    expect(find.byType(ModTopicPage),findsNothing);
    expect(tester.takeException(),isNull);
  });
}
