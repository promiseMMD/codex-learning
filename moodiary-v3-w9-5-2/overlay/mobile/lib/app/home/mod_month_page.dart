import 'dart:async';

import 'package:moodiary_i18n/moodiary_i18n.dart';
import 'package:moodiary_editor/moodiary_editor.dart';
import 'package:moodiary_models/moodiary_models.dart';
import 'package:mui/mui.dart';

import 'mod_month_composer.dart';
import 'mod_month_native.dart';
import 'mod_month_store.dart';
import 'mod_month_updates.dart';
import 'mod_month_day_preview.dart';
import 'mod_month_order.dart';

class ModMonthPage extends StatefulWidget {
  final String topicId;
  final ModNativeMonthRepository repository;
  final Future<void> Function() openLegacy;
  final bool appendOnOpen;
  final String? dayKey;
  final MoodiaryEditorController? composerController;
  const ModMonthPage({super.key, required this.topicId, required this.repository,
    required this.openLegacy, this.appendOnOpen = false, this.dayKey,
    this.composerController});
  @override
  State<ModMonthPage> createState() => _ModMonthPageState();
}

class _ModMonthPageState extends State<ModMonthPage> with WidgetsBindingObserver {
  late String _month;
  String? _day;
  ModNativeMonthSnapshot? _snapshot;
  StreamSubscription<String>? _changes;
  StreamSubscription<DiaryEvent>? _diaries;
  String _query = '';
  String? _error;
  bool _verified = false;
  bool _loading = false;
  bool _recycle = false;
  bool _opened = false;
  bool _composing = false;
  int _generation = 0;
  int _limit = 50;

  @override
  void initState() {
    super.initState();
    _day = widget.dayKey;
    _month = _day != null && modValidArchiveDay(_day!)
      ? _day!.substring(0,7) : modMonthKey(DateTime.now());
    WidgetsBinding.instance.addObserver(this);
    _changes = ModMonthUpdates.changes.listen((id) {
      if (id == widget.topicId) _reload();
    });
    _diaries = widget.repository.diaries.diaryEvents.listen((_) => _reload());
    _reload();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _reload();
  }

  @override
  void dispose() {
    _generation++;
    _changes?.cancel();
    _diaries?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  Future<void> _reload() async {
    final ticket = ++_generation;
    final month = _month;
    setState(() { _verified = false; _loading = true; _error = null; });
    try {
      if (_day != null && !modValidArchiveDay(_day!)) {
        throw StateError('invalid_daily_route');
      }
      final data = await widget.repository.load(widget.topicId, month);
      if (!mounted || ticket != _generation) return;
      setState(() { _snapshot = data; _verified = true; _loading = false; });
      if (!_opened && widget.appendOnOpen) {
        _opened = true;
        WidgetsBinding.instance.addPostFrameCallback((_) { if (mounted) _compose(); });
      }
    } catch (_) {
      if (!mounted || ticket != _generation) return;
      // Matching cached content stays readable, all writes require revalidation.
      setState(() { _verified = false; _loading = false; _error = l10n.month.readOnly; });
    }
  }

  Future<void> _compose({ModStoredBlock? block, bool summary = false,
    String action = 'edit'}) async {
    if (!_verified || _loading || _composing) return;
    _composing = true;
    try {
      final saved = await showModMonthComposer(context:context,
        repository:widget.repository,topicId:widget.topicId,monthKey:_month,
        block:block,summary:summary,action:action,initialDayKey:_day,
        editorController:widget.composerController);
      if (!mounted) return;
      if (saved != null) ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.month.savedLocal)));
      // Keep the original month after a cross-month save. Never overwrite the
      // opened composer when PC invalidation arrives during native typing.
      await _reload();
    } finally { _composing = false; }
  }

  Future<void> _pickMonth() async {
    final date = await showDatePicker(context: context,
      initialDate: _day != null && modValidArchiveDay(_day!)
        ? DateTime.parse(_day!) : DateTime.parse('$_month-01'), firstDate: DateTime(1),
      lastDate: DateTime(9999, 12, 31));
    if (!mounted || date == null) return;
    setState(() {
      _month = modMonthKey(date);
      if (_day != null) _day = modDayKey(date);
      _limit = 50;
    });
    await _reload();
  }

  void _selectMonth(String? value) {
    if (value == null || value == _month) return;
    setState(() { _month = value; _limit = 50; });
    _reload();
  }

  Future<void> _openDay(String day) async {
    if (!modValidArchiveDay(day) || _composing) return;
    await Navigator.of(context).push<void>(MaterialPageRoute(
      builder: (_) => ModMonthPage(topicId:widget.topicId,
        repository:widget.repository,openLegacy:widget.openLegacy,dayKey:day,
        composerController:widget.composerController)));
    if (mounted) await _reload();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final snapshot = _snapshot?.monthKey == _month ? _snapshot : null;
    final blocks = snapshot?.blocks ?? const <ModStoredBlock>[];
    final summaries = blocks.where((b) => b.kind == 'summary').toList();
    final summary = summaries.isEmpty ? null : summaries.single;
    final entries = blocks.where((b) => b.deleted == _recycle &&
      (_recycle || b.kind == 'entry') &&
      (_day == null || b.dayKey == _day) &&
      modBlockText(b.tiptapJson).toLowerCase().contains(_query.toLowerCase())).toList()
      ..sort((a, b) {
        final day = (a.dayKey ?? '').compareTo(b.dayKey ?? '');
        if (day != 0) return day;
        return modCompareBlocks(a,b);
      });
    final shown = entries.take(_limit).toList();
    final previews = snapshot == null
        ? const <ModDayPreview>[]
        : buildModDayPreviews(
            topicId: widget.topicId, monthKey: _month, blocks: blocks);
    final previewByDay = <String, ModDayPreview>{
      for (final item in previews) item.dayKey: item,
    };
    final writable = _verified && !_loading;
    final months = {...?snapshot?.months, _month}.toList()..sort((a,b) => b.compareTo(a));
    return Scaffold(
      appBar: AppBar(title: Text(_day == null
        ? snapshot?.topic.title ?? l10n.month.title
        : l10n.month.dayTitle(title:snapshot?.topic.title ?? l10n.month.title,day:_day!),
        maxLines:1,overflow:TextOverflow.ellipsis), actions: [
        IconButton(onPressed: _loading ? null : _reload,
          tooltip: l10n.month.refresh, icon: const Icon(LucideIcons.refreshCw)),
        IconButton(onPressed: () => setState(() { _recycle = !_recycle; _limit = 50; }),
          tooltip: l10n.diary.recycleTitle, icon: const Icon(LucideIcons.trash2)),
      ]),
      floatingActionButton: _recycle ? null : FloatingActionButton.extended(
        onPressed: writable ? _compose : null,
        icon: const Icon(LucideIcons.plus), label: Text(l10n.month.append)),
      body: Column(children: [
        if (_loading) const LinearProgressIndicator(),
        Padding(padding: const EdgeInsets.symmetric(horizontal: 16), child: Row(children: [
          if (_day != null) Expanded(child:Text(_day!))
          else Expanded(child: DropdownButton<String>(value: _month, isExpanded: true,
            items: [for (final m in months) DropdownMenuItem(value: m, child: Text(m))],
            onChanged: _selectMonth)),
          IconButton(onPressed: _pickMonth,
            tooltip: _day == null ? l10n.month.pickMonth : l10n.month.pickDay,
            icon: const Icon(LucideIcons.calendar)),
        ])),
        Padding(padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
          child: Text(l10n.month.localOnly, style: context.theme.typography.bodySmall.secondary)),
        if (_error != null) Padding(padding: const EdgeInsets.all(12),
          child: Row(children: [Expanded(child: Text(_error!)),
            TextButton(onPressed: _loading ? null : _reload, child: Text(l10n.common.retry))])),
        Padding(padding: const EdgeInsets.symmetric(horizontal: 16), child: TextField(
          onChanged: (value) => setState(() { _query = value; _limit = 50; }),
          decoration: InputDecoration(labelText:_day==null ? l10n.month.search : l10n.month.searchDay))),
        if (_day != null) Padding(padding:const EdgeInsets.all(8),
          child:Text(l10n.month.dayCount(count:blocks.where((b)=>
            b.dayKey==_day && b.kind=='entry' && !b.deleted).length))),
        if (_day == null) TextButton(onPressed: widget.openLegacy,
          child: Text(l10n.month.legacy(count: snapshot?.legacyCount ?? 0))),
        Expanded(child: ListView(padding: const EdgeInsets.fromLTRB(12, 0, 12, 100), children: [
          if (_recycle) Padding(padding: const EdgeInsets.all(12), child: Text(l10n.diary.recycleTitle)),
          if (!_recycle && _day == null) Card(child: summary == null || summary.deleted
            ? ListTile(title: Text(l10n.month.summary), subtitle: Text(l10n.month.summaryEmpty),
              trailing: TextButton(onPressed: writable ? () => _compose(block: summary,
                summary: true, action: summary?.deleted == true ? 'restore' : 'edit') : null,
                child: Text(summary?.deleted == true ? l10n.diary.recycleRestore : l10n.diary.add)))
            : ExpansionTile(key: ValueKey('summary-$_month'), title: Text(l10n.month.summary),
              children: [Padding(padding: const EdgeInsets.all(16),
                child: SelectableText(modBlockText(summary.tiptapJson))),
                _actions(summary, writable)])),
          if (shown.isEmpty && !_loading) Padding(padding: const EdgeInsets.all(24),
            child: Text(_recycle ? l10n.diary.recycleEmpty : l10n.month.empty)),
          for (var i = 0; i < shown.length; i++) ...[
            if (_day == null && (i == 0 || shown[i].dayKey != shown[i-1].dayKey))
              InkWell(onTap:shown[i].dayKey==null ? null : ()=>_openDay(shown[i].dayKey!),
                child:Padding(padding: const EdgeInsets.all(12),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(shown[i].dayKey ?? l10n.month.summary),
                    if (!_recycle && _query.isEmpty &&
                        previewByDay.containsKey(shown[i].dayKey))
                      Text(
                        (previewByDay[shown[i].dayKey]?.count ?? 0).toString() +
                            ' · ' +
                            (previewByDay[shown[i].dayKey]?.previewText ?? ''),
                        maxLines: 2, overflow: TextOverflow.ellipsis,
                        style: context.theme.typography.bodySmall.secondary,
                      ),
                    if (shown[i].dayKey != null)
                      Text(l10n.month.openDay,style:context.theme.typography.bodySmall.secondary),
                  ]))),
            Card(key: ValueKey(shown[i].blockId), child: Column(
              crossAxisAlignment: CrossAxisAlignment.start, children: [
                ListTile(title: Text(modBlockText(shown[i].tiptapJson), maxLines: 3,
                  overflow: TextOverflow.ellipsis),
                  subtitle: Text(shown[i].kind == 'summary' ? l10n.month.summary :
                    TimeOfDay.fromDateTime(DateTime.fromMillisecondsSinceEpoch(
                      shown[i].occurredAtMs)).format(context)),
                  onTap: writable ? () => _compose(block: shown[i],
                    action: shown[i].deleted ? 'restore' : 'edit') : null),
                _actions(shown[i], writable),
              ])),
          ],
          if (entries.length > _limit) TextButton(onPressed: () => setState(() => _limit += 50),
            child: Text(l10n.month.loadMore)),
        ])),
      ]),
    );
  }

  Widget _actions(ModStoredBlock block, bool writable) => Row(
    mainAxisAlignment: MainAxisAlignment.end, children: [
      TextButton(onPressed: writable ? () => _compose(block: block,
        action: block.deleted ? 'restore' : 'edit') : null,
        child: Text(block.deleted ? l10n.diary.recycleRestore : l10n.diary.edit)),
      if (!block.deleted) TextButton(onPressed: writable ? () => _compose(block: block,
        action: 'delete') : null, child: Text(l10n.common.delete)),
    ]);
}
