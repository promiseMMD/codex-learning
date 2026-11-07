import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moodiary_data/moodiary_data.dart';
import 'package:moodiary_mobile/app/home/mod_month_store.dart';

void main() {
  test('W9 disk reopen preserves heads, tombstones, history and operation receipts', () async {
    final dir = await Directory.systemTemp.createTemp('moodiary-w9-disk-');
    final file = File('${dir.path}/notes.sqlite');
    MoodiaryDatabase? openDb;
    MoodiaryDatabase open() => MoodiaryDatabase.forTesting(
      NativeDatabase(file, setup: (sqlite) {
        sqlite.execute('PRAGMA foreign_keys = ON');
        sqlite.execute('PRAGMA journal_mode = WAL');
      }),
    );
    const document = '{"type":"doc","attrs":{"v":2},"content":'
        '[{"type":"paragraph","content":[{"type":"text","text":"磁盘记录"}]}]}';
    Future<ModStoredBlock> write(ModMonthStore store, {
      String operation = 'op-disk-root-001',
      String revision = 'rev-disk-root-001',
      String? parent,
      bool deleted = false,
      String month = '2026-11',
      String day = '2026-11-07',
    }) => store.appendRevision(
      operationId: operation, blockId: 'block-disk-001', revisionId: revision,
      topicId: 'topic-disk-001', monthKey: month, kind: 'entry',
      parentRevisionId: parent, dayKey: day, occurredAtMs: 1794038400000,
      tiptapJson: document, deleted: deleted,
    );

    try {
      openDb = open();
      final first = await write(ModMonthStore(openDb));
      await openDb.close();
      openDb = null;

      openDb = open();
      var store = ModMonthStore(openDb);
      expect((await store.readMonth(topicId: 'topic-disk-001', monthKey: '2026-11'))
          .single.tiptapJson, document);
      expect((await write(store)).revisionId, first.revisionId);
      await write(store, operation: 'op-disk-move-001',
        revision: 'rev-disk-move-001', parent: first.revisionId,
        month: '2026-12', day: '2026-12-01');
      final deleted = await write(store, operation: 'op-disk-delete-001',
        revision: 'rev-disk-delete-001', parent: 'rev-disk-move-001',
        month: '2026-12', day: '2026-12-01', deleted: true);
      await openDb.close();
      openDb = null;

      openDb = open();
      store = ModMonthStore(openDb);
      expect(await store.readMonth(topicId: 'topic-disk-001', monthKey: '2026-11'), isEmpty);
      expect(await store.readMonth(topicId: 'topic-disk-001', monthKey: '2026-12'), isEmpty);
      final tombstone = (await store.readMonth(
        topicId: 'topic-disk-001', monthKey: '2026-12', includeDeleted: true,
      )).single;
      expect(tombstone.revisionId, deleted.revisionId);
      expect(tombstone.deleted, isTrue);
      // A retry of an old acknowledged operation returns that revision,
      // while the latest deleted head and its month remain untouched.
      expect((await write(store)).revisionId, first.revisionId);
      final counts = await openDb.customSelect(
        'SELECT (SELECT COUNT(*) FROM mod_month_revisions) AS revisions,'
        ' (SELECT COUNT(*) FROM mod_month_ops) AS operations,'
        ' (SELECT COUNT(*) FROM mod_month_heads) AS heads',
      ).getSingle();
      expect(counts.read<int>('revisions'), 3);
      expect(counts.read<int>('operations'), 3);
      expect(counts.read<int>('heads'), 1);
      final integrity = await openDb.customSelect('PRAGMA foreign_key_check').get();
      expect(integrity, isEmpty);
      await openDb.clearAll();
      expect((await openDb.customSelect(
        'SELECT COUNT(*) AS n FROM mod_month_revisions',
      ).getSingle()).read<int>('n'), 0);
      expect(await openDb.customSelect('PRAGMA foreign_key_check').get(), isEmpty);
    } finally {
      await openDb?.close();
      await dir.delete(recursive: true);
    }
  });
}
