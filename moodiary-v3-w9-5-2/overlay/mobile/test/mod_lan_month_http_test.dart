import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moodiary_data/moodiary_data.dart';
import 'package:moodiary_di/moodiary_di.dart';
import 'package:moodiary_mobile/app/home/mod_continuous.dart';
import 'package:moodiary_mobile/app/home/mod_lan_month_http.dart';
import 'package:moodiary_mobile/app/home/mod_month_store.dart';
import 'package:moodiary_models/moodiary_models.dart';
import 'package:moodiary_storage/moodiary_storage.dart';
import 'package:moodiary_storage/testing.dart';

const topicId = 'aac26e25-4a1d-4b4c-b256-9b0c347d36e2';
const regularId = 'bac26e25-4a1d-4b4c-b256-9b0c347d36e2';
const csrf = 'unit-test-csrf-secret';

Map<String, Object?> revision({
  String operation = 'operation-http-001',
  String block = 'block-http-001',
  String id = 'revision-http-001',
  String? parent,
  bool deleted = false,
  String text = '记录中的粗体',
  bool summary = false,
  String day = '2026-11-07',
}) => {
  'operationId': operation, 'blockId': block, 'revisionId': id,
  'parentRevisionId': parent, 'kind': summary ? 'summary' : 'entry',
  'dayKey': summary ? null : day,
  'occurredAtMs': 1794038400000, 'deleted': deleted,
  'document': {
    'type': 'doc', 'attrs': {'v': 2},
    'content': [
      {'type': 'paragraph', 'content': [
        {'type': 'text', 'text': text, 'marks': [{'type': 'bold'}]},
      ]},
    ],
  },
};

void main() {
  setUpAll(() => getIt.registerSingleton<IKVStorage>(MemoryKVStorage()));
  tearDownAll(() => getIt.reset());
  late MoodiaryDatabase db;
  late DiaryRepository repository;
  late HttpServer server;
  late HttpClient client;
  late String authority;
  late bool authorized;
  late List<String> notifications;
  Completer<void>? admitted;
  bool revokeBeforeCommit = false;
  int sessionChecks = 0;

  String path([String month = '2026-11', String topic = topicId]) =>
      '/api/v3/months/$topic/$month';

  setUp(() async {
    authorized = true;
    admitted = null;
    revokeBeforeCommit = false;
    sessionChecks = 0;
    notifications = [];
    db = MoodiaryDatabase.forTesting(NativeDatabase.memory(
      setup: (sqlite) => sqlite.execute('PRAGMA foreign_keys = ON'),
    ));
    repository = DiaryRepository(db);
    for (final id in [topicId, regularId]) {
      await repository.insertADiary(Diary.create(
        title: id == topicId ? '学习记录' : '普通日记',
        content: '{"type":"doc","attrs":{"v":2},"content":[{"type":"paragraph"}]}',
        contentText: '', imageName: [], audioName: [], videoName: [],
        tags: id == topicId ? [ModDiary.topicTag] : [],
        type: DiaryType.tiptap,
      ).copyWith(id: id));
    }
    final handler = ModLanMonthHttp(
      store: ModMonthStore(db), repository: repository,
      onCommitted: notifications.add,
    );
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    authority = '127.0.0.1:${server.port}';
    server.listen((r) async {
      final handled = await handler.tryHandle(r,
        authority: authority, csrfToken: csrf,
        isSessionActive: () {
          sessionChecks++;
          if (sessionChecks == 1) admitted?.complete();
          if (revokeBeforeCommit && sessionChecks == 4) authorized = false;
          return authorized;
        },
      );
      if (!handled) {
        r.response.statusCode = 404;
        await r.response.close();
      }
    });
    client = HttpClient();
  });

  tearDown(() async {
    client.close(force: true);
    await server.close(force: true);
    await db.close();
  });

  Future<({int status, Map<String, dynamic> body})> send(
    String url, {String method = 'GET', Object? body,
    String? token = csrf, String? origin, bool omitOrigin = false,
  }) async {
    final r = await client.openUrl(method, Uri.parse('http://$authority$url'));
    if (!omitOrigin) r.headers.set('origin', origin ?? 'http://$authority');
    if (token != null) r.headers.set('x-moodiary-csrf', token);
    if (body != null) {
      r.headers.contentType = ContentType.json;
      r.write(jsonEncode(body));
    }
    final response = await r.close();
    final json = jsonDecode(await utf8.decoder.bind(response).join());
    return (status: response.statusCode, body: (json as Map).cast<String, dynamic>());
  }

  Future<int> count(String table) async => (await db.customSelect(
    'SELECT COUNT(*) AS n FROM $table',
  ).getSingle()).read<int>('n');

  test('topic discovery lists only visible topics and discovers durable months', () async {
    final index = await send('/api/v3/topics');
    expect(index.status, 200);
    expect(index.body['topics'], hasLength(1));
    expect(index.body['topics'].single['id'], topicId);
    expect(index.body['topics'].single['months'], isEmpty);
    expect(await count('mod_month_pages'), 0);
    await send('${path()}/revisions', method: 'POST', body: revision());
    expect((await send('/api/v3/topics')).body['topics'].single['months'], ['2026-11']);
    authorized = false;
    expect((await send('/api/v3/topics')).status, 401);
    authorized = true;
    await db.customStatement('UPDATE diaries SET show = 0 WHERE id = ?', [topicId]);
    expect((await send('/api/v3/topics')).body['topics'], isEmpty);
  });

  test('HTTP GET is side-effect free; create and retry preserve rich blocks', () async {
    final empty = await send(path());
    expect(empty.status, 200);
    expect(empty.body['blocks'], isEmpty);
    expect(await count('mod_month_pages'), 0);
    final created = await send('${path()}/revisions', method: 'POST', body: revision());
    expect(created.status, 200);
    expect(created.body['state'], 'saved_on_phone');
    expect(created.body['syncState'], 'local_only');
    expect(created.body['block']['document'], revision()['document']);
    expect((await send('${path()}/revisions', method: 'POST', body: revision())).status, 200);
    expect(await count('mod_month_revisions'), 1);
    expect(await count('mod_month_pages'), 1);
    expect(await count('diaries'), 2);
    expect((await repository.getDiaryByBusinessId(regularId))?.title, '普通日记');
    expect((await send(path())).body['blocks'], hasLength(1));
    expect(notifications, [topicId, topicId]);
  });

  test('HTTP rejects anonymous, cross-origin and missing CSRF writes', () async {
    authorized = false;
    expect((await send(path())).status, 401);
    authorized = true;
    expect((await send('${path()}/revisions', method: 'POST', body: revision(), token: null)).status, 403);
    expect((await send('${path()}/revisions', method: 'POST', body: revision(), omitOrigin: true)).status, 403);
    expect((await send(path(), origin: 'http://evil.invalid')).status, 403);
    expect(await count('mod_month_revisions'), 0);
    expect(notifications, isEmpty);
  });

  test('ordinary or hidden topic cannot receive blocks; malformed body is rejected', () async {
    final noTopic = await send('${path('2026-11', regularId)}/revisions',
      method: 'POST', body: revision());
    expect(noTopic.status, 404);
    final malformed = revision()..['unknownProtocolField'] = 'not silently ignored';
    expect((await send('${path()}/revisions', method: 'POST', body: malformed)).status, 422);
    expect((await send('${path()}/revisions', method: 'POST', body: revision(day: '2026-11-31'))).status, 422);
    final invalid = revision()..['document'] = {'type': 'doc', 'attrs': {'v': 999}, 'content': []};
    expect((await send('${path()}/revisions', method: 'POST', body: invalid)).status, 422);
    await db.customStatement('UPDATE diaries SET show = 0 WHERE id = ?', [topicId]);
    expect((await send('${path()}/revisions', method: 'POST', body: revision())).status, 404);
    expect(await count('mod_month_revisions'), 0);
  });

  test('HTTP CAS retains edits; collision and stale delete return 409', () async {
    await send('${path()}/revisions', method: 'POST', body: revision());
    final edit = await send('${path()}/revisions', method: 'POST', body: revision(
      operation: 'operation-http-002', id: 'revision-http-002',
      parent: 'revision-http-001', text: '成功更新',
    ));
    expect(edit.status, 200);
    final stale = await send('${path()}/revisions', method: 'POST', body: revision(
      operation: 'operation-http-003', id: 'revision-http-003',
      parent: 'revision-http-001', deleted: true,
    ));
    expect(stale.status, 409);
    expect(stale.body['error'], 'stale_revision');
    final collision = await send('${path()}/revisions', method: 'POST',
      body: revision(text: '同幂等键的不同正文'));
    expect(collision.status, 409);
    final reused = await send('${path()}/revisions', method: 'POST', body: revision(
      operation: 'operation-http-004', block: 'block-http-004',
    ));
    expect(reused.status, 409);
    expect(reused.body['error'], 'revision_id_collision');
    expect((await send(path())).body['blocks'].single['revisionId'], 'revision-http-002');
    expect(await count('mod_month_revisions'), 2);
  });

  test('HTTP tombstone and cross-month move keep stable identity/history', () async {
    await send('${path()}/revisions', method: 'POST', body: revision());
    final move = await send('${path('2026-12')}/revisions', method: 'POST', body: revision(
      operation: 'operation-http-move', id: 'revision-http-move',
      parent: 'revision-http-001', day: '2026-12-01',
    ));
    expect(move.status, 200);
    expect((await send(path())).body['blocks'], isEmpty);
    expect((await send(path('2026-12'))).body['blocks'].single['blockId'], 'block-http-001');
    final deleted = await send('${path('2026-12')}/revisions', method: 'POST', body: revision(
      operation: 'operation-http-delete', id: 'revision-http-delete',
      parent: 'revision-http-move', day: '2026-12-01', deleted: true,
    ));
    expect(deleted.status, 200);
    expect((await send(path('2026-12'))).body['blocks'], isEmpty);
    final all = await send('${path('2026-12')}?includeDeleted=true');
    expect(all.body['blocks'].single['deleted'], true);
    expect(await count('mod_month_revisions'), 3);
  });

  test('HTTP summary is unique with a domain conflict instead of generic 500', () async {
    expect((await send('${path()}/revisions', method: 'POST', body: revision(summary: true))).status, 200);
    final duplicate = await send('${path()}/revisions', method: 'POST', body: revision(
      summary: true, operation: 'operation-http-summary',
      block: 'block-http-summary', id: 'revision-http-summary',
    ));
    expect(duplicate.status, 409);
    expect(duplicate.body['error'], 'summary_already_exists');
    expect(await count('mod_month_revisions'), 1);
  });

  test('revocation while reading a slow HTTP body cannot commit', () async {
    admitted = Completer<void>();
    final r = await client.postUrl(Uri.parse('http://$authority${path()}/revisions'));
    r.headers.contentType = ContentType.json;
    r.headers.set('origin', 'http://$authority');
    r.headers.set('x-moodiary-csrf', csrf);
    r.write('{');
    await r.flush();
    await admitted!.future.timeout(const Duration(seconds: 5));
    authorized = false;
    r.write(jsonEncode(revision()).substring(1));
    final result = await r.close();
    expect(result.statusCode, 403);
    await result.drain<void>();
    expect(await count('mod_month_revisions'), 0);
    expect(notifications, isEmpty);
  });

  test('revocation at commit boundary rolls back head, revision and receipt', () async {
    revokeBeforeCommit = true;
    final result = await send('${path()}/revisions', method: 'POST', body: revision());
    // Checks: initial admission, after body, transaction entry, before commit.
    expect(result.status, 403);
    for (final table in ['mod_month_pages', 'mod_month_blocks', 'mod_month_heads',
        'mod_month_revisions', 'mod_month_ops']) {
      expect(await count(table), 0, reason: table);
    }
    expect(notifications, isEmpty);
  });

  test('creation metadata comes from the phone and stays stable after editing', () async {
    final create=await send('${path()}/revisions',method:'POST',body:revision());
    final first=create.body['block'] as Map;
    expect(first['createdAtMs'],isA<int>());
    expect(first['createdAtMs'],greaterThan(0));
    final next=await send('${path()}/revisions',method:'POST',body:revision(
      operation:'operation-http-created-edit',id:'revision-http-created-edit',parent:first['revisionId'] as String,text:'edited'));
    expect(next.status,200);
    expect((next.body['block'] as Map)['createdAtMs'],first['createdAtMs']);
    final forged=revision(operation:'operation-http-forged',id:'revision-http-forged')..['createdAtMs']=0;
    expect((await send('${path()}/revisions',method:'POST',body:forged)).status,422);
  });

  test('large payload and invalid month fail without partial storage', () async {
    expect((await send('${path('2026-13')}/revisions', method: 'POST', body: revision())).status, 422);
    expect((await send('${path()}/revisions', method: 'POST',
      body: revision(text: 'x' * 270000))).status, 413);
    expect(await count('mod_month_revisions'), 0);
  });
}
