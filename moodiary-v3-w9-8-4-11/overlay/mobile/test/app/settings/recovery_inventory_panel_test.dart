// ignore_for_file: deprecated_member_use

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moodiary_i18n/moodiary_i18n.dart';
import 'package:moodiary_mobile/app/settings/storage/recovery_inventory_controller.dart';
import 'package:moodiary_mobile/app/settings/storage/recovery_inventory_panel.dart';
import 'package:moodiary_sync/src/data/mod_month_restore_inventory_v2.dart';
import 'package:mui/mui.dart';

void main() {
  setUpAll(() {
    setupPluralResolvers();
    LocaleSettings.setLocaleSync(AppLocale.zh);
  });

  Future<void> showPanel(
    WidgetTester tester,
    ModRestoreInventorySnapshotV2 snapshot,
  ) async {
    await tester.binding.setSurfaceSize(const Size(400, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ProviderScope(
        retry: (_, _) => null,
        overrides: [
          recoveryInventoryProvider.overrideWith((ref) async => snapshot),
        ],
        child: TranslationProvider(
          child: MaterialApp(
            theme: buildMuiTheme(brightness: Brightness.light),
            locale: const Locale('zh'),
            supportedLocales: AppLocaleUtils.supportedLocales,
            home: const Scaffold(
              body: CustomScrollView(
                slivers: [RecoveryInventoryPanel()],
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('empty inventory is explicit and read-only', (tester) async {
    await showPanel(tester, const ModRestoreInventorySnapshotV2([]));
    expect(find.text('隔离恢复副本'), findsOneWidget);
    expect(find.text('未发现隔离恢复副本'), findsOneWidget);
    expect(find.textContaining('不会创建目录'), findsOneWidget);
    expect(find.byType(FilledButton), findsNothing);
    expect(find.text('删除'), findsNothing);
    expect(find.text('修复'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('verified copy shows measured size and opens inspection details', (
    tester,
  ) async {
    const entry = ModRestoreInventoryEntryV2(
      path: '/app/support/.moodiary-v2-private-recovery/workspace-1',
      state: ModRestoreInventoryStateV2.ready,
      bytes: 1536,
      files: 4,
      activeDirectory:
          '/app/support/.moodiary-v2-private-recovery/workspace-1/generation-slot/generations/generation-1',
    );
    await showPanel(tester, const ModRestoreInventorySnapshotV2([entry]));
    expect(find.text('已验证恢复副本'), findsOneWidget);
    await tester.tap(find.text('恢复工作区 1'));
    await tester.pumpAndSettle();
    expect(find.text('1.50 KB'), findsOneWidget);
    expect(find.text('目录路径'), findsOneWidget);
    expect(find.text('活跃副本路径'), findsOneWidget);
    expect(
      find.textContaining('.moodiary-v2-private-recovery/workspace-1'),
      findsWidgets,
    );
    expect(find.text('本页面只读，不提供删除、修复或正式恢复操作。'), findsOneWidget);
    expect(find.byType(FilledButton), findsNothing);
    expect(find.text('删除'), findsNothing);
    expect(find.text('修复'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('unverified states are visible and never become cleanup actions', (
    tester,
  ) async {
    const snapshot = ModRestoreInventorySnapshotV2([
      ModRestoreInventoryEntryV2(
        path: '/private/workspace-a',
        state: ModRestoreInventoryStateV2.recoveryRequired,
        bytes: 4096,
        files: 3,
        activeDirectory: null,
      ),
      ModRestoreInventoryEntryV2(
        path: '/private/foreign-note.txt',
        state: ModRestoreInventoryStateV2.unrecognized,
        bytes: null,
        files: null,
        activeDirectory: null,
      ),
      ModRestoreInventoryEntryV2(
        path: '/private/workspace-b',
        state: ModRestoreInventoryStateV2.needsReview,
        bytes: 8192,
        files: 5,
        activeDirectory: null,
      ),
    ]);
    await showPanel(tester, snapshot);
    expect(find.text('恢复事务未完成'), findsOneWidget);
    expect(find.text('未识别项目'), findsOneWidget);
    expect(find.text('需要人工检查'), findsOneWidget);
    expect(find.textContaining('大小未知'), findsOneWidget);
    expect(find.byType(FilledButton), findsNothing);
    expect(find.text('删除'), findsNothing);
    expect(find.text('修复'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('failed inspection can be retried without changing files', (
    tester,
  ) async {
    var calls = 0;
    await tester.binding.setSurfaceSize(const Size(400, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ProviderScope(
        retry: (_, _) => null,
        overrides: [
          recoveryInventoryProvider.overrideWith((ref) async {
            calls++;
            if (calls == 1) throw StateError('inspection failed');
            return const ModRestoreInventorySnapshotV2([]);
          }),
        ],
        child: TranslationProvider(
          child: MaterialApp(
            theme: buildMuiTheme(brightness: Brightness.light),
            locale: const Locale('zh'),
            supportedLocales: AppLocaleUtils.supportedLocales,
            home: const Scaffold(
              body: CustomScrollView(
                slivers: [RecoveryInventoryPanel()],
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('读取失败'), findsOneWidget);
    await tester.tap(find.byTooltip('重新扫描'));
    await tester.pumpAndSettle();
    expect(calls, 2);
    expect(find.text('未发现隔离恢复副本'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
