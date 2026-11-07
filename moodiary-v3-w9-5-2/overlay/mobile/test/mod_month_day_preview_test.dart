import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:moodiary_mobile/app/home/mod_month_day_preview.dart';
import 'package:moodiary_mobile/app/home/mod_month_store.dart';

const topic = 'aac26e25-4a1d-4b4c-b256-9b0c347d36e2';
const month = '2026-11';

String doc(String text) => jsonEncode({
  'type': 'doc',
  'attrs': {'v': 2},
  'content': [
    {'type': 'paragraph', 'content': [
      {'type': 'text', 'text': text}
    ]}
  ],
});

ModStoredBlock block(String id, String day, int event, {
  String? text,
  int edited = 10,
  int created = 0,
  bool deleted = false,
  String kind = 'entry',
  String topicId = topic,
  String monthKey = month,
}) => ModStoredBlock(
  blockId: id, revisionId: 'revision-$id', parentRevisionId: null,
  topicId: topicId, monthKey: monthKey, kind: kind,
  dayKey: kind == 'summary' ? null : day,
  occurredAtMs: event, editedAtMs: edited, createdAtMs:created,
  tiptapJson: doc(text ?? id), deleted: deleted,
);

void main() {
  test('last three by event time, not edited time; previews stay chronological', () {
    final items = [
      block('morning', '2026-11-07', 100, edited: 999999),
      block('noon', '2026-11-07', 200),
      block('afternoon', '2026-11-07', 300),
      block('night', '2026-11-07', 400),
    ];
    final result = buildModDayPreviews(topicId: topic, monthKey: month, blocks: items);
    expect(result, hasLength(1));
    expect(result.single.count, 4);
    expect(result.single.recent.map((e) => e.blockId),
        ['noon', 'afternoon', 'night']);
    expect(result.single.previewText, 'noon · afternoon · night');
    expect(() => result.single.recent.clear(), throwsUnsupportedError);
  });

  test('different days newest first; deleted and summary do not create cards', () {
    final result = buildModDayPreviews(topicId: topic, monthKey: month, blocks: [
      block('older', '2026-11-02', 111),
      block('newer', '2026-11-07', 222),
      block('removed', '2026-11-08', 333, deleted: true),
      block('summary-one', '2026-11-09', 444, kind: 'summary'),
    ]);
    expect(result.map((e) => e.dayKey), ['2026-11-07', '2026-11-02']);
    expect(result.map((e) => e.count), [1, 1]);
  });

  test('event-time tie is stable by block ID regardless of input order', () {
    final result = buildModDayPreviews(topicId: topic, monthKey: month, blocks: [
      block('zzzzz', '2026-11-07', 100),
      block('aaaaa', '2026-11-07', 100),
      block('bbbbb', '2026-11-07', 100),
    ]);
    expect(result.single.recent.map((e) => e.blockId),
        ['aaaaa', 'bbbbb', 'zzzzz']);
  });

  test('same-time recent three use immutable creation time before stable ID', () {
    final result=buildModDayPreviews(topicId:topic,monthKey:month,blocks:[
      block('a-newest','2026-11-07',100,created:400),
      block('z-oldest','2026-11-07',100,created:100,edited:999999),
      block('b-third','2026-11-07',100,created:300),
      block('y-second','2026-11-07',100,created:200),
    ]);
    expect(result.single.recent.map((e)=>e.blockId),['y-second','b-third','a-newest']);
  });

  test('reject invalid calendar day and cross-month metadata', () {
    expect(() => buildModDayPreviews(topicId: topic, monthKey: month,
      blocks: [block('invalid', '2026-11-31', 1)]), throwsStateError);
    expect(() => buildModDayPreviews(topicId: topic, monthKey: month,
      blocks: [block('wrong', '2026-12-01', 1)]), throwsStateError);
    expect(() => buildModDayPreviews(topicId: topic, monthKey: month,
      blocks: [block('mixed', '2026-11-01', 1, monthKey: '2026-10')]), throwsStateError);
    expect(() => buildModDayPreviews(topicId: topic, monthKey: month,
      blocks: [block('wrong-topic', '2026-11-01', 1, topicId: 'other')]), throwsStateError);
  });

  test('reject duplicate IDs to avoid hiding a conflicting head', () {
    final item = block('same-identity', '2026-11-07', 100);
    expect(() => buildModDayPreviews(topicId: topic, monthKey: month,
      blocks: [item, item]), throwsStateError);
  });

  test('only empty, deleted and summary blocks yield no daily preview', () {
    expect(buildModDayPreviews(topicId: topic, monthKey: month,
      blocks: [block('deleted', '2026-11-07', 1, deleted: true),
        block('summary', '2026-11-07', 2, kind: 'summary')]), isEmpty);
  });
}
