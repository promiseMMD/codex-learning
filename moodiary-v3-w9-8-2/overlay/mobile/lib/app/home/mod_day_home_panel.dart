// W9.8.2: compact, read-only daily cards above the normal Diary list.
// These are NOT ordinary Diary records: all editing goes through W9 CAS.
import 'dart:async';

import 'package:moodiary_data/moodiary_data.dart';
import 'package:moodiary_di/moodiary_di.dart';
import 'package:moodiary_models/moodiary_models.dart';
import 'package:mui/mui.dart';

import 'mod_continuous.dart' show ModDiary, ModLegacyTopicPage;
import 'mod_day_home_index.dart';
import 'mod_lan_service.dart';
import 'mod_month_native.dart';
import 'mod_month_page.dart';
import 'mod_month_store.dart';
import 'mod_month_updates.dart';

class ModDayHomePanel extends StatefulWidget {
  final ModDailyHomeIndex? repository;
  final Future<void> Function(BuildContext, ModHomeDay)? openDay;

  const ModDayHomePanel({super.key, this.repository, this.openDay});

  @override
  State<ModDayHomePanel> createState() => _ModDayHomePanelState();
}

class _ModDayHomePanelState extends State<ModDayHomePanel>
    with WidgetsBindingObserver {
  late final ModDailyHomeIndex _repository;
  StreamSubscription<String>? _monthChanges;
  StreamSubscription<DiaryEvent>? _diaryChanges;
  List<ModHomeDay> _days = const [];
  bool _showHidden = false;
  bool _loading = false;
  bool _saving = false;
  bool _failed = false;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    _repository = widget.repository ?? _createRepository();
    _monthChanges = ModMonthUpdates.changes.listen((_) => _reload());
    if (widget.repository == null) {
      _diaryChanges = ModDiary.repo.diaryEvents.listen((_) => _reload());
    }
    WidgetsBinding.instance.addObserver(this);
    _reload();
  }

  static ModDailyHomeIndex _createRepository() {
    final db = getIt<MoodiaryDatabase>();
    return ModDailyHomeIndex(
      store: ModMonthStore(db),
      dayMap: ModDayMap(db),
      topicTitle: (topicId) async {
        final diary = await ModDiary.repo.getDiaryByBusinessId(topicId);
        if (diary == null || !diary.show || !ModDiary.isTopic(diary)) {
          return null;
        }
        return diary.title.trim().isEmpty ? '长期主题' : diary.title;
      },
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _reload();
  }

  @override
  void dispose() {
    _generation++;
    _monthChanges?.cancel();
    _diaryChanges?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  Future<void> _reload() async {
    final ticket = ++_generation;
    if (!mounted) return;
    setState(() => _loading = true);
    try {
      final next = await _repository.load();
      if (!mounted || ticket != _generation) return;
      setState(() {
        _days = next;
        _failed = false;
        _loading = false;
      });
    } catch (_) {
      if (!mounted || ticket != _generation) return;
      // Fail closed; stale cards must not offer writes or navigation.
      setState(() {
        _days = const [];
        _failed = true;
        _loading = false;
      });
    }
  }

  Future<void> _toggle(ModHomeDay day) async {
    if (_saving || _loading || _failed) return;
    setState(() => _saving = true);
    try {
      await _repository.setVisible(day, !day.visibleLocal);
      if (mounted) await _reload();
    } catch (_) {
      if (mounted) {
        setState(() => _failed = true);
        await _reload();
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _openDay(ModHomeDay day) async {
    if (_failed || _loading || _saving || !day.visibleLocal && !_showHidden) {
      return;
    }
    if (widget.openDay case final callback?) {
      await callback(context, day);
    } else {
      final repository = ModNativeMonthRepository(
        store: ModMonthStore(getIt<MoodiaryDatabase>()),
        diaries: ModDiary.repo,
        onCommitted: ModLanServer.instance.notifyMonthCommitted,
      );
      await Navigator.of(context).push<void>(MaterialPageRoute<void>(
        builder: (_) => ModMonthPage(
          topicId: day.topicId, dayKey: day.dayKey,
          repository: repository,
          openLegacy: () => Navigator.of(context).push<void>(
            MaterialPageRoute<void>(
              builder: (_) => ModLegacyTopicPage(topicId: day.topicId),
            ),
          ),
        ),
      ));
    }
    if (mounted) await _reload();
  }

  @override
  Widget build(BuildContext context) {
    if (_failed) {
      return Padding(
        padding: const EdgeInsets.all(12),
        child: Row(children: [
          const Icon(Icons.warning_amber_outlined),
          const SizedBox(width: 8),
          const Expanded(
            child: Text('每日记录读取异常。已暂停首页入口，请在长期主题页检查本机数据。'),
          ),
          TextButton(onPressed: _loading ? null : _reload, child: const Text('重试')),
        ]),
      );
    }
    if (_days.isEmpty) {
      if (_loading) return const SizedBox.shrink();
      return const SizedBox.shrink();
    }

    final shown = _days.where((d) => _showHidden || d.visibleLocal).toList();
    final hidden = _days.where((d) => !d.visibleLocal).length;
    const limit = 20;
    final visible = shown.take(limit).toList(growable: false);
    final more = shown.length > limit;

    return Column(mainAxisSize: MainAxisSize.min, children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(14, 8, 10, 4),
        child: Row(children: [
          const Expanded(
            child: Text('每日长期记录 · 仅本机',
              maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
          if (_loading) const SizedBox(
            width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)),
          if (hidden > 0)
            IconButton(
              tooltip: _showHidden ? '收起已隐藏' : '显示已隐藏',
              onPressed: _saving ? null :
                () => setState(() => _showHidden = !_showHidden),
              icon: Icon(_showHidden
                ? Icons.visibility_off_outlined
                : Icons.visibility_outlined),
            ),
        ]),
      ),
      if (shown.isEmpty)
        const Padding(
          padding: EdgeInsets.all(12),
          child: Text('这些每日记录已从首页隐藏；可以打开“显示隐藏”恢复。'),
        ),
      if (visible.isNotEmpty) SizedBox(
        height: 176,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          itemCount: visible.length + (more ? 1 : 0),
          separatorBuilder: (_, _) => const SizedBox(width: 8),
          itemBuilder: (context, index) {
            if (index >= visible.length) {
              return const SizedBox(
                width: 208, child: Center(
                  child: Text('这里只显示最近20天；全部记录请进入长期主题查看。'),
                ),
              );
            }
            final day = visible[index];
            return SizedBox(width: 256,
              child: Card(
                child: InkWell(
                  onTap: _saving || _loading ? null : () => _openDay(day),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(children: [
                          Expanded(child: Text(day.topicTitle,
                            maxLines: 1, overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.titleSmall)),
                          IconButton(
                            tooltip: day.visibleLocal
                              ? '从首页隐藏' : '在首页显示',
                            onPressed: _saving || _loading
                              ? null : () => _toggle(day),
                            iconSize: 18,
                            icon: Icon(day.visibleLocal
                              ? Icons.visibility_off_outlined
                              : Icons.visibility_outlined),
                          ),
                        ]),
                        Text(day.dayKey + ' · ' + day.count.toString() + ' 条',
                          style: Theme.of(context).textTheme.labelSmall),
                        const SizedBox(height: 8),
                        Expanded(child: Text(
                          day.preview.isEmpty ? '（无文本预览）' : day.preview,
                          maxLines: 3, overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.bodySmall)),
                        const Align(
                          alignment: Alignment.centerRight,
                          child: Text('打开当天记录',
                            style: TextStyle(fontSize: 12)),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ),
      const SizedBox(height: 4),
    ]);
  }
}
