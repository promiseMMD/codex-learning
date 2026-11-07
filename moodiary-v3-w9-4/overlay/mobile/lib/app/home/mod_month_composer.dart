import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:moodiary_editor/moodiary_editor.dart';
import 'package:moodiary_i18n/moodiary_i18n.dart';
import 'package:moodiary_utils/moodiary_utils.dart';
import 'package:mui/mui.dart';

import 'mod_lan_rich.dart';
import 'mod_month_native.dart';
import 'mod_month_store.dart';

const _emptyBody = '{"type":"doc","attrs":{"v":2},"content":[{"type":"paragraph"}]}';

/// A separate route retains its original parent revision during all refreshes.
/// No temporary ordinary Diary or automatic local/cloud draft is created.
class ModMonthComposer extends StatefulWidget {
  final ModNativeMonthRepository repository;
  final String topicId;
  final String monthKey;
  final ModStoredBlock? block;
  final bool summary;
  final String action; // edit, delete, restore
  final MoodiaryEditorController? editorController;
  const ModMonthComposer({super.key, required this.repository,
    required this.topicId, required this.monthKey, this.block,
    this.summary = false, this.action = 'edit', this.editorController});
  @override
  State<ModMonthComposer> createState() => _ModMonthComposerState();
}

class _ModMonthComposerState extends State<ModMonthComposer> {
  late final _editor = widget.editorController ?? MoodiaryEditorController();
  final _blockId = uuidV7();
  late String _body;
  late DateTime _event;
  late String? _day;
  ModMonthMutation? _attempt;
  String? _error;
  bool _busy = false;
  bool _conflict = false;
  bool _allowExit = false;
  bool get _summary => widget.block?.kind == 'summary' || widget.summary;
  bool get _editing => widget.action == 'edit';
  bool get _locked => _busy || _attempt != null;

  @override
  void initState() {
    super.initState();
    final block = widget.block;
    _body = block?.tiptapJson ?? _emptyBody;
    final now = DateTime.now();
    _event = block == null
      ? (modMonthKey(now) == widget.monthKey ? now :
        DateTime(int.parse(widget.monthKey.substring(0, 4)),
          int.parse(widget.monthKey.substring(5)), 1, now.hour, now.minute))
      : DateTime.fromMillisecondsSinceEpoch(block.occurredAtMs);
    _day = _summary ? null : block?.dayKey ?? modDayKey(_event);
  }

  void _message(String message) {
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)));
  }

  Future<void> _details(String message) => showDialog<void>(context: context,
    builder: (c) => AlertDialog(title: Text(l10n.month.title),
      content: SingleChildScrollView(child: SelectableText(message)),
      actions: [TextButton(onPressed: () => Navigator.pop(c),
        child: Text(l10n.common.close))]));

  Future<void> _date() async {
    if (_locked || _summary) return;
    final initial = DateTime.parse(_day!);
    final date = await showDatePicker(context: context,
      initialDate: initial, firstDate: DateTime(1), lastDate: DateTime(9999, 12, 31));
    if (!mounted || date == null || _locked) return;
    setState(() {
      _day = modDayKey(date);
      _event = DateTime(date.year, date.month, date.day, _event.hour,
        _event.minute, _event.second, _event.millisecond, _event.microsecond);
    });
  }

  Future<void> _time() async {
    if (_locked || _summary) return;
    final time = await showTimePicker(context: context,
      initialTime: TimeOfDay.fromDateTime(_event));
    if (!mounted || time == null || _locked) return;
    final day = DateTime.parse(_day!);
    setState(() => _event = DateTime(day.year, day.month, day.day,
      time.hour, time.minute));
  }

  Future<void> _copyDraft() async {
    try {
      if (_editing && _attempt == null && !_busy) {
        // Copy uses the same acknowledged read as Save; never claims an older
        // debounced value is the complete current draft.
        _body = await _editor.snapshot();
      }
      final payload = _attempt?.toJson() ?? {
        'schemaVersion': 1, 'topicId': widget.topicId,
        'monthKey': _summary ? widget.monthKey : _day!.substring(0, 7),
        'blockId': widget.block?.blockId ?? _blockId,
        'parentRevisionId': widget.block?.revisionId,
        'kind': _summary ? 'summary' : 'entry', 'dayKey': _day,
        'occurredAtMs': _event.millisecondsSinceEpoch,
        'document': jsonDecode(_body), 'draft': true,
      };
      await Clipboard.setData(ClipboardData(
        text: const JsonEncoder.withIndent('  ').convert(payload)));
      _message(l10n.common.copied);
    } catch (_) { _message(l10n.month.snapshotFailed); }
  }

  Future<void> _leave() async {
    if (_busy || _allowExit) return;
    final discard = await showDialog<bool>(context: context,
      builder: (c) => AlertDialog(title: Text(l10n.month.leaveTitle),
        content: Text(_attempt != null ? l10n.month.leaveUncertain : l10n.month.leaveMessage),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false),
            child: Text(l10n.month.keepEditing)),
          TextButton(onPressed: () => Navigator.pop(c, true),
            child: Text(l10n.month.discard)),
        ]));
    if (discard != true || !mounted) return;
    setState(() => _allowExit = true);
    Navigator.of(context).pop();
  }

  Future<void> _save() async {
    if (_busy || _conflict) return;
    setState(() { _busy = true; _error = null; });
    try {
      if (_attempt == null) {
        if (_editing) {
          await _editor.blur();
          final current = await _editor.snapshot();
          // Keep unsupported pasted nodes in the editor and fail closed. No
          // flattening, normalization, or temporary Diary can lose that draft.
          ModLanRichDocument.validate(jsonDecode(current));
          if (modBlockText(current).isEmpty) {
            if (mounted) setState(() { _error = l10n.month.emptyBody; _busy = false; });
            return;
          }
          _body = current;
          _attempt = ModMonthMutation(
            operationId: uuidV7(), revisionId: uuidV7(),
            blockId: widget.block?.blockId ?? _blockId, topicId: widget.topicId,
            monthKey: _summary ? widget.monthKey : _day!.substring(0, 7),
            kind: _summary ? 'summary' : 'entry',
            parentRevisionId: widget.block?.revisionId, dayKey: _day,
            occurredAtMs: _event.millisecondsSinceEpoch, tiptapJson: _body,
          );
        } else {
          _attempt = ModMonthMutation.fromBlock(widget.block!,
            operationId: uuidV7(), revisionId: uuidV7(),
            deleted: widget.action == 'delete');
        }
      }
      final saved = await widget.repository.commit(_attempt!);
      if (!mounted) return;
      setState(() { _allowExit = true; _busy = false; });
      Navigator.of(context).pop(saved);
    } on ModMonthStoreException catch (e) {
      if (!mounted) return;
      // Domain rejections are final for this immutable parent/payload. Never
      // automatically rebase to a PC edit, deletion, or existing summary.
      setState(() {
        _busy = false;
        _conflict = _attempt != null;
        _error = e.code == 'topic_not_available'
          ? l10n.month.topicUnavailable : l10n.month.conflict;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = _attempt == null ? l10n.month.snapshotFailed : l10n.month.uncertain;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final title = !_editing
      ? (widget.action == 'delete' ? l10n.month.deleteTitle : l10n.diary.recycleRestore)
      : (_summary ? l10n.month.summary : l10n.month.record);
    return PopScope(
      canPop: _allowExit,
      onPopInvokedWithResult: (didPop, _) { if (!didPop) _leave(); },
      child: Scaffold(
        appBar: AppBar(title: Text(title), leading: IconButton(
          onPressed: _busy ? null : _leave, tooltip: l10n.common.close,
          icon: const Icon(LucideIcons.x)),
          actions: [IconButton(onPressed: _busy ? null : _copyDraft,
            tooltip: l10n.month.copyDraft, icon: const Icon(LucideIcons.copy)),
            IconButton(onPressed: () => _details('${l10n.month.localOnly}\n\n${l10n.month.timezone}'),
              tooltip: l10n.common.more, icon: const Icon(LucideIcons.info))]),
        body: SafeArea(child: Column(children: [
          Padding(padding: const EdgeInsets.all(12),
            child: Text(l10n.month.localOnly, maxLines: 2, overflow: TextOverflow.ellipsis,
              style: context.theme.typography.bodySmall.secondary)),
          if (_editing && !_summary) Wrap(spacing: 8, children: [
            TextButton.icon(onPressed: _locked ? null : _date,
              icon: const Icon(LucideIcons.calendar), label: Text(_day!)),
            TextButton.icon(onPressed: _locked ? null : _time,
              icon: const Icon(LucideIcons.clock),
              label: Text(TimeOfDay.fromDateTime(_event).format(context))),
          ]),
          if (_error != null) Padding(padding: const EdgeInsets.all(12),
            child: Row(children: [Expanded(child: Text(_error!, maxLines: 3,
              overflow: TextOverflow.ellipsis)), IconButton(onPressed: () => _details(_error!),
              tooltip: l10n.common.more, icon: const Icon(LucideIcons.info))])),
          Expanded(child: _editing ? AbsorbPointer(absorbing: _locked,
            child: MoodiaryEditor(controller: _editor, bodyOnly: true,
              initialContent: widget.block?.tiptapJson ?? _emptyBody,
              onChanged: (value) { if (!_locked) _body = value; }))
            : SingleChildScrollView(padding: const EdgeInsets.all(16),
              child: SelectableText(modBlockText(_body)))),
          if (_editing) SingleChildScrollView(scrollDirection: Axis.horizontal,
            child: Row(children: [
              for (final item in <(EditorCommand, IconData, String)>[
                (EditorCommand.toggleBold, LucideIcons.bold, l10n.editor.toolbar.bold),
                (EditorCommand.toggleItalic, LucideIcons.italic, l10n.editor.toolbar.italic),
                (EditorCommand.toggleUnderline, LucideIcons.underline, l10n.editor.toolbar.underline),
                (EditorCommand.toggleStrike, LucideIcons.strikethrough, l10n.editor.toolbar.strike),
                (EditorCommand.toggleCode, LucideIcons.code, l10n.editor.toolbar.inlineCode),
                (EditorCommand.setHeading, LucideIcons.heading2, l10n.month.heading),
                (EditorCommand.setParagraph, LucideIcons.type, l10n.month.paragraph),
                (EditorCommand.undo, LucideIcons.undo2, l10n.editor.toolbar.undo),
                (EditorCommand.redo, LucideIcons.redo2, l10n.editor.toolbar.redo),
              ]) IconButton(onPressed: _locked ? null : () => _editor.exec(item.$1,
                item.$1 == EditorCommand.setHeading ? {'level': 2} : null),
                tooltip: item.$3, icon: Icon(item.$2)),
            ])),
          Padding(padding: const EdgeInsets.all(12), child: SizedBox(width: double.infinity,
            child: FilledButton(onPressed: _busy || _conflict ? null : _save,
              child: Text(_busy ? l10n.diary.saving : _attempt != null
                ? l10n.month.retrySame : _editing ? l10n.common.save
                : widget.action == 'delete' ? l10n.common.delete : l10n.diary.recycleRestore)))),
        ])),
      ),
    );
  }
}
