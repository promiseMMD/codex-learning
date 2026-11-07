import 'dart:async';
import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moodiary_data/moodiary_data.dart';
import 'package:moodiary_di/moodiary_di.dart';
import 'package:moodiary_editor/moodiary_editor.dart';
import 'package:moodiary_i18n/moodiary_i18n.dart';
import 'package:moodiary_mobile/app/home/mod_month_composer.dart';
import 'package:moodiary_mobile/app/home/mod_month_native.dart';
import 'package:moodiary_mobile/app/home/mod_month_store.dart';
import 'package:moodiary_storage/moodiary_storage.dart';
import 'package:moodiary_storage/testing.dart';
import 'package:mui/mui.dart';

const validBody = '{"type":"doc","attrs":{"v":2},"content":[{"type":"paragraph","content":[{"type":"text","text":"native draft"}]}]}';
const topicId = 'aac26e25-4a1d-4b4c-b256-9b0c347d36e2';

class _Editor extends MoodiaryEditorController {
  String document = validBody;
  bool fail = false;
  @override Future<void> blur() async {}
  @override Future<String> snapshot() async {
    if(fail) throw TimeoutException('no editor acknowledgement');
    return document;
  }
}

class _Repository extends ModNativeMonthRepository {
  final attempts = <ModMonthMutation>[];
  bool uncertain = false;
  bool conflict = false;
  _Repository(ModMonthStore store,DiaryRepository diaries):super(store:store,diaries:diaries);
  @override Future<ModStoredBlock> commit(ModMonthMutation attempt) async {
    attempts.add(attempt);
    if(conflict) throw const ModMonthStoreException('stale_revision');
    if(uncertain) throw StateError('lost acknowledgement');
    return ModStoredBlock(blockId:attempt.blockId,revisionId:attempt.revisionId,
      parentRevisionId:attempt.parentRevisionId,topicId:topicId,
      monthKey:attempt.monthKey,kind:attempt.kind,dayKey:attempt.dayKey,
      occurredAtMs:attempt.occurredAtMs,editedAtMs:1794038400000,
      tiptapJson:attempt.tiptapJson,deleted:attempt.deleted);
  }
}

void main() {
  late MoodiaryDatabase db;
  late _Repository repository;
  late _Editor editor;
  setUp(() {
    getIt.registerSingleton<IKVStorage>(MemoryKVStorage());
    db=MoodiaryDatabase.forTesting(NativeDatabase.memory());
    repository=_Repository(ModMonthStore(db),DiaryRepository(db));
    editor=_Editor();
  });
  tearDown(() async { await db.close(); await getIt.reset(); });
  Future<void> mount(WidgetTester tester) async {
    await tester.pumpWidget(TranslationProvider(child:MaterialApp(
      theme:buildMuiTheme(brightness:.light),
      localizationsDelegates:const [...GlobalMaterialLocalizations.delegates,
        GlobalMuiLocalizations.delegate],
      builder:(context,child)=>MaterialUiCompatibilityBridge(child:child!),
      home:ModMonthComposer(repository:repository,topicId:topicId,
        monthKey:'2026-11',editorController:editor))));
    await tester.pumpAndSettle();
  }

  testWidgets('missing editor acknowledgement never calls the writer',(tester) async {
    editor.fail=true;
    await mount(tester);
    expect(tester.widget<MoodiaryEditor>(find.byType(MoodiaryEditor)).bodyOnly,true);
    await tester.tap(find.widgetWithText(FilledButton,l10n.common.save));
    await tester.pumpAndSettle();
    expect(repository.attempts,isEmpty);
    expect(find.text(l10n.month.snapshotFailed),findsOneWidget);
  });

  testWidgets('unsupported rich paste remains editable and cannot be silently flattened',(tester) async {
    editor.document=jsonEncode({'type':'doc','attrs':{'v':2},'content':[
      {'type':'table','content':[]} ]});
    await mount(tester);
    await tester.tap(find.widgetWithText(FilledButton,l10n.common.save));
    await tester.pumpAndSettle();
    expect(repository.attempts,isEmpty);
    expect(editor.document,contains('table'));
    expect(tester.widget<FilledButton>(find.byType(FilledButton).last).onPressed,isNotNull);
  });

  testWidgets('uncertain save freezes one immutable operation and retry reuses every byte',(tester) async {
    repository.uncertain=true;
    await mount(tester);
    await tester.tap(find.widgetWithText(FilledButton,l10n.common.save));
    await tester.pumpAndSettle();
    expect(find.text(l10n.month.uncertain),findsOneWidget);
    final first=repository.attempts.single;
    editor.document=validBody.replaceAll('native draft','must not replace attempt');
    await tester.tap(find.widgetWithText(FilledButton,l10n.month.retrySame));
    await tester.pumpAndSettle();
    expect(repository.attempts.length,2);
    expect(identical(repository.attempts.last,first),true);
    expect(repository.attempts.last.toJson(),first.toJson());
    expect(repository.attempts.last.tiptapJson,validBody);
  });

  testWidgets('conflict preserves draft and does not offer an automatic rebase',(tester) async {
    repository.conflict=true;
    await mount(tester);
    await tester.tap(find.widgetWithText(FilledButton,l10n.common.save));
    await tester.pumpAndSettle();
    expect(find.text(l10n.month.conflict),findsOneWidget);
    expect(repository.attempts.single.tiptapJson,validBody);
    expect(tester.widget<FilledButton>(find.byType(FilledButton).last).onPressed,isNull);
    expect(find.byTooltip(l10n.month.copyDraft),findsOneWidget);
  });
}
