"""W9.4 native month workspace over the existing W9 store, without projection."""
from pathlib import Path
import base64
import io
import shutil
import sys
import zipfile

root = Path(sys.argv[1]).resolve()
here = Path(__file__).resolve().parent
generated = here / 'generated-i18n.b64'
if generated.exists():
    target = root / 'packages/foundation/moodiary_i18n/lib/i18n'
    target.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(io.BytesIO(base64.b64decode(generated.read_bytes()))) as z:
        assert set(z.namelist()) == {'strings.g.dart', 'strings_en.g.dart', 'strings_zh.g.dart'}
        assert z.testzip() is None
        for name in z.namelist():
            (target / name).write_bytes(z.read(name))
for source in (here / 'overlay').rglob('*'):
    if source.is_file():
        target = root / source.relative_to(here / 'overlay')
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, target)

def patch(path, old, new):
    p = root / path
    value = p.read_text()
    if new in value:
        return
    assert value.count(old) == 1, f'{path}: expected one patch anchor: {old[:70]}'
    p.write_text(value.replace(old, new, 1))

patch('mobile/pubspec.yaml', 'version: 2.9.2+98', 'version: 2.9.2+99')

continuous = 'mobile/lib/app/home/mod_continuous.dart'
patch(continuous, '''// All content is persisted as ordinary Diary objects so the upstream
// WebDAV, ZIP backup and encrypted-sync paths continue to transport it.''', '''// Legacy topics/children below remain ordinary Diary objects. W9.4's native
// monthly workspace uses the separate W9 revision tables and is local-only.''')
patch(continuous, "import 'mod_monthly_index.dart';", "import 'mod_monthly_index.dart';\nimport 'mod_month_page.dart';\nimport 'mod_month_native.dart';\nimport 'mod_month_store.dart';\nimport 'mod_lan_service.dart';")
patch(continuous, 'class ModTopicPage extends StatefulWidget {', '''class ModTopicPage extends StatelessWidget {
  const ModTopicPage({super.key, required this.topicId, this.append = false});
  final String topicId;
  final bool append;
  @override
  Widget build(BuildContext context) => ModMonthPage(
    topicId: topicId,
    appendOnOpen: append,
    repository: ModNativeMonthRepository(
      store: ModMonthStore(getIt<MoodiaryDatabase>()),
      diaries: ModDiary.repo,
      onCommitted: ModLanServer.instance.notifyMonthCommitted,
    ),
    openLegacy: () => Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => ModLegacyTopicPage(topicId: topicId))),
  );
}

class ModLegacyTopicPage extends StatefulWidget {''')
patch(continuous, 'const ModTopicPage({super.key, required this.topicId});', 'const ModLegacyTopicPage({super.key, required this.topicId});')
patch(continuous, 'State<ModTopicPage> createState() => _ModTopicPageState();', 'State<ModLegacyTopicPage> createState() => _ModTopicPageState();')
patch(continuous, 'class _ModTopicPageState extends State<ModTopicPage> {', 'class _ModTopicPageState extends State<ModLegacyTopicPage> {')
patch(continuous, 'onPressed: () => ModDiary.isTopic(d) ? ModEntrySheet.show(context, d) : _open(context, d),', '''onPressed: () => ModDiary.isTopic(d)
                    ? Navigator.of(context).push(MaterialPageRoute<void>(
                        builder: (_) => ModTopicPage(topicId: d.id, append: true)))
                    : _open(context, d),''')

service = 'mobile/lib/app/home/mod_lan_service.dart'
patch(service, "import 'mod_lan_month_http.dart';", "import 'mod_lan_month_http.dart';\nimport 'mod_month_updates.dart';")
patch(service, '  void _publishDiaryEvent(DiaryEvent event) {', '''  // Called only after a successful SQLite commit. Notification failure cannot
  // turn an already saved block into an apparent failed write.
  void notifyMonthCommitted(String topicId) {
    ModMonthUpdates.publish(topicId);
    if (_server != null && !_stopping) {
      try { _hub.publish(kind: 'updated', id: topicId, source: 'local'); }
      catch (_) { /* A disconnect does not roll back a committed record. */ }
    }
  }

  void _publishDiaryEvent(DiaryEvent event) {''')
patch(service, "onCommitted: (topicId) => _hub.publish(\n          kind: 'updated', id: topicId, source: 'local'),", 'onCommitted: notifyMonthCommitted,')

editor = 'packages/feature_base/moodiary_editor/lib/src/moodiary_editor.dart'
patch(editor, "import 'transport/editor_transport.dart';", "import 'transport/editor_transport.dart';\nimport 'transport/editor_snapshot.dart';")
patch(editor, '  final bool readOnly;', '  final bool readOnly;\n\n  /// Hide diary metadata/title when editing one structured record body.\n  final bool bodyOnly;')
patch(editor, '    this.readOnly = false,', '    this.readOnly = false,\n    this.bodyOnly = false,')
patch(editor, '  final _flushes = <String, Completer<void>>{};', '  final _snapshots = EditorSnapshotQueue();\n  final _flushes = <String, Completer<void>>{};')
patch(editor, '    _readyTimeout?.cancel();\n    unawaited(_overlay?.resume());', '    _readyTimeout?.cancel();\n    _snapshots.dispose();\n    unawaited(_overlay?.resume());')
patch(editor, "      case 'flushed':", "      case 'snapshot':\n        if (payload is Map && payload['reqId'] is String) {\n          _snapshots.complete(payload['reqId'] as String, payload['document']);\n        }\n        return;\n      case 'flushed':")
patch(editor, "      'fontScale': widget.fontScale,", "      'fontScale': widget.fontScale,\n      'bodyOnly': widget.bodyOnly,")
patch(editor, '(oldWidget.firstLineIndent != widget.firstLineIndent ||', '(oldWidget.bodyOnly != widget.bodyOnly ||\n            oldWidget.firstLineIndent != widget.firstLineIndent ||')
patch(editor, '  Future<void> _flush() async {', '''  Future<String> _snapshot() async {
    if (!_activated || !_jsReady || _transport == null || _loadError != null) {
      throw StateError('editor_not_ready');
    }
    return _snapshots.take((id) => _run(
      'window.MoodiaryBridge.snapshot(${jsonEncode(id)})'));
  }

  Future<void> _flush() async {''')
patch(editor, '  Future<void> flush() async {\n    await _host?._flush();\n  }', '''  Future<void> flush() async {
    await _host?._flush();
  }

  /// A fresh, acknowledged document; throws on detach, broken content or timeout.
  /// Unlike the legacy best-effort flush this may safely gate structured writes.
  Future<String> snapshot() {
    final host = _host;
    if (host == null) throw StateError('editor_not_attached');
    return host._snapshot();
  }''')

kit = 'packages/feature_base/moodiary_editor/editor/src/core/editor/kit.ts'
patch(kit, '  currentState(): EditorState | null', '  currentState(): EditorState | null\n  currentDocument(): string | null')
patch(kit, '    setContent: loadContent,', "    currentDocument: () => editor && !editor.isDestroyed && !broken ? serialize() : null,\n    setContent: loadContent,")
bridge = 'packages/feature_base/moodiary_editor/editor/src/core/bridge/index.ts'
patch(bridge, '  exec: (command: string, args?: Record<string, unknown>)', '''  snapshot: (reqId: string) => {
    flushChange()
    post('snapshot', { reqId, document: api?.currentDocument() ?? null })
  },
  exec: (command: string, args?: Record<string, unknown>)''')
theme = 'packages/feature_base/moodiary_editor/editor/src/core/bridge/theme.ts'
patch(theme, '  fontScale: number', '  fontScale: number\n  bodyOnly?: boolean')
p = root / theme
value = p.read_text()
anchor = 'export function applyTheme('
start = value.index(anchor)
brace = value.index('{', start)
insertion = "\n  document.documentElement.dataset.bodyOnly = String(theme.bodyOnly === true)"
# The actual argument name is checked, rather than guessing a generated API.
signature = value[start:brace]
if insertion not in value:
    assert 'theme:' in signature, signature
    value = value[:brace+1] + insertion + value[brace+1:]
    p.write_text(value)
css = root / 'packages/feature_base/moodiary_editor/editor/src/styles/editor.scss'
rule = '\n/* Structured bodies have no independent diary title or metadata. */\n[data-body-only="true"] :is(.md-title, .md-meta, .md-links) { display: none !important; }\n'
if rule not in css.read_text():
    css.write_text(css.read_text() + rule)

# W4 introduced atomic native saves; upstream's pre-W4 mock still only handles
# unconditional updates. Keep its interleaving tests and model the new CAS API.
controller_test = 'packages/feature_base/moodiary_editor/test/edit_controller_test.dart'
patch(controller_test, '  @override\n  Future<void> insertADiary(', '''  @override
  Future<bool> updateADiaryIfCurrent({
    required Diary newDiary,
    required Diary expectedSnapshot,
    IndexMode index = .inline,
  }) async {
    operations.add('update');
    indexes.add(index);
    final gate = updateGate;
    updateGate = null;
    if (gate != null) await gate.wait();
    if (writeLatency case final latency?) await Future<void>.delayed(latency);
    // Check at the write boundary, after any externally gated concurrent edit.
    if (newDiary.id != expectedSnapshot.id || stored != expectedSnapshot) return false;
    stored = newDiary;
    writes.add(newDiary);
    events.add(DiaryUpdated(newDiary));
    return true;
  }

  @override
  Future<void> insertADiary(''')
patch(controller_test, '''    expect(container.read(provider).value?.content, 'local');
    expect(await controller.autoSave(), DraftSaveResult.saved);
    expect(repository.stored?.content, 'local');''', '''    expect(container.read(provider).value?.content, 'local');
    expect(await controller.autoSave(), DraftSaveResult.failed);
    expect(container.read(provider).value?.content, 'local');
    expect(repository.stored?.content, 'external');''')
patch(controller_test, '''    gate.release.complete();
    expect(await saving, DraftSaveResult.saved);
    expect(repository.stored?.content, 'local');
    expect(repository.writes, hasLength(2));''', '''    gate.release.complete();
    expect(await saving, DraftSaveResult.failed);
    expect(container.read(provider).value?.content, 'local');
    expect(repository.stored?.content, 'external');
    expect(repository.writes, hasLength(1));''')
print('Applied W9.4 native workspace; no native Diary projection or sync format change')
