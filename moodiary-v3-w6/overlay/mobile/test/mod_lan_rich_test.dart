import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moodiary_data/moodiary_data.dart';
import 'package:moodiary_di/moodiary_di.dart';
import 'package:moodiary_mobile/app/home/mod_lan_rich.dart';
import 'package:moodiary_mobile/app/home/mod_lan_write.dart';
import 'package:moodiary_storage/moodiary_storage.dart';
import 'package:moodiary_storage/testing.dart';

const stableId = '0fa41b8e-9cb6-4ab3-88e7-aa91984720bb';

Map<String, dynamic> richDoc([String value = '工程笔记']) => {
  'type': 'doc', 'attrs': {'v': 2},
  'content': [
    {
      'type': 'heading', 'attrs': {'level': 2},
      'content': [
        {'type': 'text', 'text': value, 'marks': [{'type': 'bold'}]},
      ],
    },
    {
      'type': 'paragraph',
      'content': [
        {'type': 'text', 'text': '记录：'},
        {'type': 'text', 'text': 'Stage / Alignment',
          'marks': [{'type': 'italic'}]},
        {'type': 'hardBreak'},
        {'type': 'text', 'text': '报告',
          'marks': [{'type': 'link', 'attrs': {'href': 'https://example.org/a'}}]},
      ],
    },
  ],
};

void main() {
  test('W6 supports lossless headings, bold, italic, safe links and hard breaks', () {
    final v = ModLanRichDocument.validate(richDoc());
    final decoded = jsonDecode(v);
    expect(decoded['content'][0]['type'], 'heading');
    expect(decoded['content'][0]['content'][0]['marks'][0]['type'], 'bold');
    expect(decoded['content'][1]['content'][2]['type'], 'hardBreak');
    expect(decoded['content'][1]['content'][3]['marks'][0]['attrs']['href'],
        'https://example.org/a');
  });

  test('W6 rejects links using script and relative schemes', () {
    for (final url in ['javascript:alert(1)', 'data:text/html,hello',
        'file:///etc/passwd', '//evil.org', 'http:/no-host']) {
      final doc = richDoc();
      ((doc['content'] as List)[1]['content'] as List)[3]['marks'][0]['attrs']['href'] = url;
      expect(() => ModLanRichDocument.validate(doc),
          throwsA(isA<ModLanWriteException>()), reason: url);
    }
  });

  test('W6 rejects future schema, media, unknown marks and node-level attrs', () {
    final invalid = <Map<String, dynamic>>[
      {...richDoc(), 'attrs': {'v': 3}},
      {...richDoc(), 'content': [
        {'type': 'image', 'attrs': {'src': 'image-local'}}
      ]},
      {...richDoc(), 'content': [
        {'type': 'paragraph', 'content': [
          {'type': 'text', 'text': 'x', 'marks': [{'type': 'unknown'}]}
        ]}
      ]},
      {...richDoc(), 'content': [
        {'type': 'paragraph', 'attrs': {'hidden': 'a'}, 'content': []}
      ]},
      {...richDoc(), 'content': [
        {'type': 'paragraph', 'content': [
          {'type': 'text', 'text': 'x', 'marks': [{'type': 'link', 'attrs': {
            'href': 'https://example.org', 'target': '_blank'
          }}]}
        ]}
      ]},
    ];
    for (final doc in invalid) {
      expect(() => ModLanRichDocument.validate(doc),
          throwsA(isA<ModLanWriteException>()));
    }
  });

  test('W6 enforces schema-size budget', () {
    final doc = richDoc(List.filled(200001, 'x').join());
    expect(() => ModLanRichDocument.validate(doc),
        throwsA(isA<ModLanWriteException>()));
  });

  group('database-backed rich note CAS', () {
    late MoodiaryDatabase db;
    late DiaryRepository repository;
    late ModLanRichWriter writer;

    setUpAll(() => getIt.registerSingleton<IKVStorage>(MemoryKVStorage()));
    setUp(() {
      db = MoodiaryDatabase.forTesting(NativeDatabase.memory());
      repository = DiaryRepository(db);
      writer = ModLanRichWriter(repository);
    });
    tearDown(() => db.close());

    test('create, read, idempotent retry keep the same rich document', () async {
      final doc = richDoc();
      final args = {'id': stableId, 'title': '精密设备', 'document': doc};
      final created = await writer.create(args);
      expect(ModLanRichDocument.canEdit(created), isTrue);
      expect(jsonDecode(created.content), doc);
      expect(created.contentText, contains('工程笔记'));
      final duplicate = await writer.create(args);
      expect(duplicate.id, created.id);
      expect(ModLanWriteSafety.revision(duplicate),
          ModLanWriteSafety.revision(created));
      expect(ModLanWriteSafety.canEdit(created), isFalse,
          reason: 'W4 textarea must never flatten a rich note');
    });

    test('CAS rejects stale concurrent edits without losing winner', () async {
      final original = await writer.create({
        'id': stableId, 'title': '测试', 'document': richDoc()
      });
      final revision = ModLanWriteSafety.revision(original);
      final winner = await writer.update(stableId, {
        'title': '电脑编辑', 'document': richDoc('新版本'),
        'revision': revision,
      });
      expect(winner.title, '电脑编辑');
      expect(winner.content, contains('新版本'));
      await expectLater(
        writer.update(stableId, {
          'title': '过期写入', 'document': richDoc('旧版本'),
          'revision': revision,
        }),
        throwsA(isA<ModLanWriteException>()
            .having((x) => x.code, 'code', 'stale_revision')),
      );
      final stored = await writer.load(stableId);
      expect(stored.title, '电脑编辑');
      expect(stored.content, contains('新版本'));
    });

    test('malformed new document is rejected before modifying the stored note', () async {
      final stored = await writer.create({
        'id': stableId, 'title': '稳定', 'document': richDoc()
      });
      final doc = richDoc();
      (doc['attrs'] as Map)['v'] = 999;
      await expectLater(writer.update(stableId, {
        'title': '危险覆盖', 'document': doc,
        'revision': ModLanWriteSafety.revision(stored),
      }), throwsA(isA<ModLanWriteException>()));
      expect((await writer.load(stableId)).content, stored.content);
    });
  });
}
