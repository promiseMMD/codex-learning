import 'dart:async';

/// Correlates acknowledged snapshots. Empty/missing replies and late replies
/// cannot authorize a save. Unlike best-effort flush, timeout is an error.
class EditorSnapshotQueue {
  final _pending = <String, Completer<String>>{};
  int _sequence = 0;
  bool _disposed = false;

  Future<String> take(Future<void> Function(String id) send, {
    Duration timeout = const Duration(seconds: 3),
  }) async {
    if (_disposed) throw StateError('editor_detached');
    final id = 'snapshot-${_sequence++}';
    final done = _pending[id] = Completer<String>();
    // Attach the timeout/error consumer before dispatch can complete a reply.
    final result = done.future.timeout(timeout);
    try {
      unawaited(Future<void>.sync(() => send(id)).catchError((Object e,
        StackTrace stack) {
        _pending.remove(id)?.completeError(e, stack);
      }));
      return await result;
    } finally {
      _pending.remove(id);
    }
  }

  void complete(String id, Object? document) {
    final done = _pending.remove(id);
    if (done == null) return;
    if (document is! String || document.isEmpty) {
      done.completeError(StateError('editor_content_unavailable'));
    } else {
      done.complete(document);
    }
  }

  void dispose() {
    _disposed = true;
    for (final done in _pending.values) {
      done.completeError(StateError('editor_detached'));
    }
    _pending.clear();
  }
}
