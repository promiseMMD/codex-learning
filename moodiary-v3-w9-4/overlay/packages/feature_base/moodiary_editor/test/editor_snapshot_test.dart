import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:moodiary_editor/src/moodiary_editor.dart';
import 'package:moodiary_editor/src/transport/editor_snapshot.dart';

void main() {
  test('snapshot refuses an unattached editor rather than returning stale data', () {
    expect(() => MoodiaryEditorController().snapshot(), throwsStateError);
  });

  test('snapshot waits for its own acknowledged document, not another request', () async {
    final queue = EditorSnapshotQueue();
    final ids = <String>[];
    final first = queue.take((id) async { ids.add(id); });
    final second = queue.take((id) async { ids.add(id); });
    queue.complete('foreign-reply', 'wrong');
    queue.complete(ids[1], 'second-current-document');
    queue.complete(ids[0], 'first-current-document');
    expect(await first, 'first-current-document');
    expect(await second, 'second-current-document');
    queue.dispose();
  });

  test('timeout is an error and a late reply cannot satisfy the next save', () async {
    final queue = EditorSnapshotQueue();
    late String old;
    await expectLater(queue.take((id) async { old = id; },
      timeout: const Duration(milliseconds: 5)), throwsA(isA<TimeoutException>()));
    final current = queue.take((id) async {
      queue.complete(old, 'late-old-draft');
      queue.complete(id, 'new-current-document');
    });
    expect(await current, 'new-current-document');
    queue.dispose();
  });

  test('broken content or missing API reply cannot authorize a save', () async {
    final queue = EditorSnapshotQueue();
    await expectLater(queue.take((id) async => queue.complete(id, null)), throwsStateError);
    await expectLater(queue.take((id) async => queue.complete(id, '')), throwsStateError);
    queue.dispose();
  });

  test('dispatch failure and detach reject pending snapshots', () async {
    final queue = EditorSnapshotQueue();
    await expectLater(queue.take((_) async => throw StateError('transport failed')), throwsStateError);
    final pending = queue.take((_) async {});
    final expectation = expectLater(pending, throwsStateError);
    queue.dispose();
    await expectation;
    await expectLater(queue.take((_) async {}), throwsStateError);
  });
}
