import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:moodiary_files/moodiary_files.dart';
import 'package:moodiary_i18n/moodiary_i18n.dart';
import 'package:moodiary_sync/src/data/mod_month_restore_inventory_v2.dart';
import 'package:mui/mui.dart';

import 'recovery_inventory_controller.dart';

String _recoveryText(String zh, String en) =>
    LocaleSettings.currentLocale == AppLocale.zh ? zh : en;

String _recoveryBytes(int bytes) {
  final value = AppFiles.bytesToUnits(bytes);
  return '${value['size']} ${value['unit']}';
}

String _recoveryState(ModRestoreInventoryStateV2 state) => switch (state) {
  .empty => _recoveryText('空工作区', 'Empty workspace'),
  .ready => _recoveryText('已验证恢复副本', 'Verified recovery copy'),
  .recoveryRequired =>
    _recoveryText('恢复事务未完成', 'Incomplete recovery transaction'),
  .needsReview => _recoveryText('需要人工检查', 'Manual review required'),
  .unrecognized => _recoveryText('未识别项目', 'Unrecognized item'),
};

String _recoveryStateHelp(ModRestoreInventoryStateV2 state) => switch (state) {
  .empty => _recoveryText(
    '此工作区目前没有已安装的恢复副本。',
    'This workspace currently has no installed recovery copy.',
  ),
  .ready => _recoveryText(
    '该副本通过当前 V2 身份检查；这不代表它已写入正式日记。',
    'The copy passed the current V2 identity checks; it has not been applied to live diaries.',
  ),
  .recoveryRequired => _recoveryText(
    '检测到未完成的恢复日志。本页面不会调用恢复或修复流程，请人工检查。',
    'An unfinished recovery journal was found. This page will not recover or repair it; inspect it manually.',
  ),
  .needsReview => _recoveryText(
    '发现额外文件、链接或身份异常。所有内容均予以保留。',
    'Unexpected files, links, or identity anomalies were found. All contents are preserved.',
  ),
  .unrecognized => _recoveryText(
    '该项目未被识别为应用拥有的工作区，不读取其内部内容。',
    'This item is not recognized as an app-owned workspace; its contents are not traversed.',
  ),
};

class RecoveryInventoryPanel extends ConsumerWidget {
  const RecoveryInventoryPanel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final inventory = ref.watch(recoveryInventoryProvider);
    return MSliverSettingGroup(
      title: _recoveryText('隔离恢复副本', 'Isolated recovery copies'),
      children: [
        ListTile(
          leading: const Icon(Icons.inventory_2_outlined),
          title: Text(_recoveryText('恢复副本概览', 'Recovery copy overview')),
          subtitle: Text(_summary(inventory)),
          trailing: IconButton(
            tooltip: _recoveryText('重新扫描', 'Rescan'),
            onPressed: inventory.isLoading
                ? null
                : () => ref.invalidate(recoveryInventoryProvider),
            icon: const Icon(Icons.refresh),
          ),
        ),
        ...inventory.when(
          data: (snapshot) => _entries(context, snapshot),
          error: (error, stack) => [
            ListTile(
              leading: const Icon(Icons.error_outline),
              title: Text(_recoveryText('读取失败', 'Could not inspect recovery copies')),
              subtitle: Text(
                _recoveryText(
                  '文件未被修改。请检查设备状态后重新扫描。',
                  'No files were modified. Check device status and rescan.',
                ),
              ),
            ),
          ],
          loading: () => [
            ListTile(
              leading: const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              title: Text(_recoveryText('正在读取恢复副本', 'Inspecting recovery copies')),
            ),
          ],
        ),
        MNoticeItem(
          icon: LucideIcons.info,
          title: _recoveryText(
            '只读检查：不会删除、修复或恢复任何文件。副本占用已包含在“其他”分类中，此处仅展示明细。',
            'Read-only inspection: no files are deleted, repaired, or restored. Their space is already included in “Other”; this panel only shows the breakdown.',
          ),
        ),
      ],
    );
  }

  String _summary(AsyncValue<ModRestoreInventorySnapshotV2> inventory) =>
      inventory.when(
        data: (snapshot) {
          if (snapshot.entries.isEmpty) {
            return _recoveryText(
              '未发现隔离恢复副本；检查过程不会创建目录。',
              'No isolated recovery copies found. Inspection does not create directories.',
            );
          }
          final measured = snapshot.entries.where((e) => e.bytes != null).length;
          final unknown = snapshot.entries.length - measured;
          final size = measured == 0
              ? _recoveryText('容量未知', 'Size unknown')
              : _recoveryText(
                  '已测量 ${_recoveryBytes(snapshot.knownBytes)}',
                  'Measured ${_recoveryBytes(snapshot.knownBytes)}',
                );
          final suffix = unknown == 0
              ? ''
              : _recoveryText(' · ${unknown} 项大小未知', ' · ${unknown} size unknown');
          return _recoveryText(
            '${snapshot.entries.length} 项 · $size$suffix',
            '${snapshot.entries.length} item(s) · $size$suffix',
          );
        },
        error: (_, _) => _recoveryText('读取失败', 'Inspection failed'),
        loading: () => _recoveryText('正在读取…', 'Inspecting…'),
      );

  List<Widget> _entries(
    BuildContext context,
    ModRestoreInventorySnapshotV2 snapshot,
  ) {
    if (snapshot.entries.isEmpty) {
      return [
        ListTile(
          leading: const Icon(Icons.folder_off_outlined),
          title: Text(_recoveryText('未发现隔离恢复副本', 'No isolated recovery copies found')),
          subtitle: Text(
            _recoveryText(
              '没有创建新目录，也没有修改任何文件。',
              'No directory was created and no files were changed.',
            ),
          ),
        ),
      ];
    }
    return [
      for (var i = 0; i < snapshot.entries.length; i++)
        ListTile(
          leading: Icon(
            snapshot.entries[i].state == ModRestoreInventoryStateV2.ready
                ? Icons.verified_outlined
                : snapshot.entries[i].state == ModRestoreInventoryStateV2.empty
                ? Icons.folder_outlined
                : Icons.warning_amber_outlined,
          ),
          title: Text(_entryTitle(snapshot.entries[i], i)),
          subtitle: Text(_entrySubtitle(snapshot.entries[i])),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => _showDetails(context, snapshot.entries[i], i),
        ),
      if (snapshot.requiresExplicitRetentionDecision)
        MNoticeItem(
          icon: LucideIcons.info,
          title: _recoveryText(
            '检测到隔离恢复副本。重置应用数据前，必须人工确认其保留安排。',
            'Isolated recovery copies exist. Confirm their retention before resetting app data.',
          ),
        ),
      if (snapshot.hasUnverifiedItems)
        MNoticeItem(
          icon: LucideIcons.triangleAlert,
          title: _recoveryText(
            '存在需要人工检查的项目。请勿将未知内容视为缓存或可清理文件。',
            'Some items require manual review. Do not treat unknown contents as cache or disposable files.',
          ),
        ),
    ];
  }

  String _entryTitle(ModRestoreInventoryEntryV2 entry, int index) {
    final prefix = entry.state == ModRestoreInventoryStateV2.unrecognized
        ? _recoveryText('未识别项目', 'Unrecognized item')
        : _recoveryText('恢复工作区', 'Recovery workspace');
    return '$prefix ${index + 1}';
  }

  String _entrySubtitle(ModRestoreInventoryEntryV2 entry) {
    final size = entry.bytes == null
        ? _recoveryText('容量未知', 'Size unknown')
        : _recoveryBytes(entry.bytes!);
    final files = entry.files == null
        ? _recoveryText('文件数未知', 'File count unknown')
        : _recoveryText('${entry.files} 个文件', '${entry.files} file(s)');
    return '${_recoveryState(entry.state)} · $size · $files';
  }

  Future<void> _showDetails(
    BuildContext context,
    ModRestoreInventoryEntryV2 entry,
    int index,
  ) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 24),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _entryTitle(entry, index),
                  style: Theme.of(sheetContext).textTheme.titleLarge,
                ),
                const SizedBox(height: 16),
                _detail(
                  sheetContext,
                  _recoveryText('状态', 'State'),
                  _recoveryState(entry.state),
                ),
                _detail(
                  sheetContext,
                  _recoveryText('已测量空间', 'Measured size'),
                  entry.bytes == null
                      ? _recoveryText('未知', 'Unknown')
                      : _recoveryBytes(entry.bytes!),
                ),
                _detail(
                  sheetContext,
                  _recoveryText('文件数量', 'File count'),
                  entry.files?.toString() ??
                      _recoveryText('未知', 'Unknown'),
                ),
                const SizedBox(height: 12),
                Text(_recoveryText('目录路径', 'Directory path')),
                const SizedBox(height: 4),
                SelectableText(entry.path),
                if (entry.activeDirectory != null) ...[
                  const SizedBox(height: 12),
                  Text(_recoveryText('活跃副本路径', 'Active copy path')),
                  const SizedBox(height: 4),
                  SelectableText(entry.activeDirectory!),
                ],
                const SizedBox(height: 16),
                Text(_recoveryStateHelp(entry.state)),
                const SizedBox(height: 16),
                Text(
                  _recoveryText(
                    '本页面只读，不提供删除、修复或正式恢复操作。',
                    'This page is read-only. It provides no delete, repair, or live-restore operation.',
                  ),
                  style: Theme.of(sheetContext).textTheme.bodySmall,
                ),
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton(
                    onPressed: () => Navigator.of(sheetContext).pop(),
                    child: Text(_recoveryText('关闭', 'Close')),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _detail(BuildContext context, String label, String value) => Padding(
    padding: const EdgeInsets.only(bottom: 10),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(width: 104, child: Text(label)),
        Expanded(child: Text(value)),
      ],
    ),
  );
}
