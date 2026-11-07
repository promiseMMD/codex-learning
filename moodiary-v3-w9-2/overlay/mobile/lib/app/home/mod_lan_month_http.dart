// W9.2: authenticated HTTP adapter for the existing durable W9 block store.
// These local revisions are not yet transported by WebDAV or projected into
// ordinary Diaries. Responses must never claim cloud synchronization.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:moodiary_data/moodiary_data.dart';
import 'package:moodiary_logging/moodiary_logging.dart';

import 'mod_continuous.dart' show ModDiary;
import 'mod_lan_write.dart';
import 'mod_month_store.dart';

class ModLanMonthHttp {
  final ModMonthStore store;
  final DiaryRepository repository;
  final void Function(String topicId)? onCommitted;

  const ModLanMonthHttp({
    required this.store,
    required this.repository,
    this.onCommitted,
  });

  static const prefix = '/api/v3/months/';
  static const topicsPath = '/api/v3/topics';
  static const maxRequestBytes = 262144;
  static const _fields = {
    'operationId', 'blockId', 'revisionId', 'parentRevisionId',
    'kind', 'dayKey', 'occurredAtMs', 'document', 'deleted',
  };
  static const _conflicts = {
    'operation_id_collision', 'revision_id_collision', 'stale_revision',
    'duplicate_block_root', 'unknown_block_parent', 'block_identity_conflict',
    'block_conflicted_or_missing_head', 'block_has_multiple_heads',
    'cross_block_parent', 'summary_already_exists', 'summary_cannot_move_month',
  };

  static Map<String, Object?> _block(ModStoredBlock b) => {
    'blockId': b.blockId,
    'revisionId': b.revisionId,
    'parentRevisionId': b.parentRevisionId,
    'topicId': b.topicId,
    'monthKey': b.monthKey,
    'kind': b.kind,
    'dayKey': b.dayKey,
    'occurredAtMs': b.occurredAtMs,
    'editedAtMs': b.editedAtMs,
    'document': jsonDecode(b.tiptapJson),
    'deleted': b.deleted,
  };

  static Future<void> _reply(HttpRequest r, int status, Object body) async {
    r.response.statusCode = status;
    r.response.headers.contentType = ContentType.json;
    r.response.headers.set(HttpHeaders.cacheControlHeader, 'no-store');
    r.response.headers.set('X-Content-Type-Options', 'nosniff');
    r.response.write(jsonEncode(body));
    await r.response.close();
  }

  static Never _reject(int status, String code) =>
      throw ModLanWriteException(status, code);

  static Future<Map<String, dynamic>> _body(HttpRequest r) async {
    if (r.headers.contentType?.mimeType != 'application/json') {
      _reject(415, 'json_content_type_required');
    }
    if (r.headers.contentLength > maxRequestBytes) {
      _reject(413, 'request_too_large');
    }
    final bytes = BytesBuilder(copy: false);
    var total = 0;
    await for (final part in r.timeout(const Duration(seconds: 30))) {
      total += part.length;
      if (total > maxRequestBytes) _reject(413, 'request_too_large');
      bytes.add(part);
    }
    try {
      final result = jsonDecode(utf8.decode(bytes.takeBytes()));
      if (result is Map<String, dynamic>) return result;
    } on FormatException {
      _reject(400, 'bad_json');
    }
    _reject(400, 'bad_json');
  }

  Future<void> _requireTopic(String topicId) async {
    ModLanWriteSafety.id(topicId);
    final topic = await repository.getDiaryByBusinessId(topicId);
    if (topic == null || !topic.show || !ModDiary.isTopic(topic) ||
        ModDiary.isChild(topic)) {
      _reject(404, 'topic_not_found');
    }
  }

  static void _active(bool Function() isSessionActive) {
    if (!isSessionActive()) _reject(403, 'session_revoked');
  }

  /// Called by ModLanServer after its ordinary session/origin gates. Recheck
  /// here as well so a slow body or queued transaction cannot retain a grant.
  /// Returning false leaves every pre-existing LAN route untouched.
  Future<bool> tryHandle(
    HttpRequest r, {
    required String authority,
    required String csrfToken,
    required bool Function() isSessionActive,
  }) async {
    final topicIndex = r.uri.path == topicsPath;
    if (!topicIndex && !r.uri.path.startsWith(prefix)) return false;
    try {
      final mutation = r.method != 'GET' && r.method != 'HEAD';
      final origin = r.headers.value('origin');
      if (r.headers.value(HttpHeaders.hostHeader) != authority ||
          (mutation ? origin != 'http://$authority' :
              origin != null && origin != 'http://$authority')) {
        _reject(403, 'unsafe_origin');
      }
      if (!isSessionActive()) _reject(401, 'pairing_required');
      if (mutation && (csrfToken.isEmpty ||
          r.headers.value('x-moodiary-csrf') != csrfToken)) {
        _reject(403, 'csrf_required');
      }

      if (topicIndex) {
        if (r.method != 'GET') _reject(405, 'method_not_allowed');
        if (r.uri.hasQuery) _reject(422, 'invalid_query');
        final topics = await store.db.transaction(() async {
          _active(isSessionActive);
          final all = await repository.getAllDiaries();
          final visible = all.where((d) => d.show && ModDiary.isTopic(d) &&
              !ModDiary.isChild(d)).toList()
            ..sort((a, b) => a.title.compareTo(b.title));
          final result = <Map<String, Object?>>[];
          for (final topic in visible) {
            result.add({
              'id': topic.id, 'title': topic.title,
              'months': await store.monthKeysForTopic(topic.id),
              'legacyCount': all.where((d) => d.show && ModDiary.isChild(d) &&
                  ModDiary.topicIdOf(d) == topic.id).length,
            });
          }
          _active(isSessionActive);
          return result;
        });
        await _reply(r, 200, {'schemaVersion': 1, 'topics': topics});
        return true;
      }

      final parts = r.uri.pathSegments;
      final read = r.method == 'GET' && parts.length == 5;
      final write = r.method == 'POST' && parts.length == 6 &&
          parts[5] == 'revisions';
      if (!read && !write) _reject(405, 'method_not_allowed');
      final topicId = parts[3];
      final monthKey = parts[4];

      if (read) {
        if (r.uri.queryParameters.keys.any((k) => k != 'includeDeleted') ||
            (r.uri.queryParameters.containsKey('includeDeleted') &&
             !const {'true', 'false'}.contains(
               r.uri.queryParameters['includeDeleted']))) {
          _reject(422, 'invalid_query');
        }
        final blocks = await store.db.transaction(() async {
          _active(isSessionActive);
          await _requireTopic(topicId);
          final result = await store.readMonth(
            topicId: topicId, monthKey: monthKey,
            includeDeleted: r.uri.queryParameters['includeDeleted'] == 'true',
          );
          _active(isSessionActive);
          return result;
        });
        await _reply(r, 200, {
          'schemaVersion': 1, 'topicId': topicId, 'monthKey': monthKey,
          'syncState': 'local_only',
          'blocks': blocks.map(_block).toList(growable: false),
        });
      } else {
        if (r.uri.hasQuery) _reject(422, 'invalid_query');
        final body = await _body(r);
        _active(isSessionActive);
        if (body.keys.toSet().difference(_fields).isNotEmpty ||
            _fields.difference(body.keys.toSet()).isNotEmpty ||
            body['operationId'] is! String || body['blockId'] is! String ||
            body['revisionId'] is! String || body['kind'] is! String ||
            (body['parentRevisionId'] != null &&
             body['parentRevisionId'] is! String) ||
            (body['dayKey'] != null && body['dayKey'] is! String) ||
            body['occurredAtMs'] is! int || body['deleted'] is! bool) {
          _reject(422, 'invalid_month_revision');
        }
        final saved = await store.db.transaction(() async {
          _active(isSessionActive);
          await _requireTopic(topicId);
          final result = await store.appendRevision(
            operationId: body['operationId'] as String,
            blockId: body['blockId'] as String,
            revisionId: body['revisionId'] as String,
            topicId: topicId,
            monthKey: monthKey,
            kind: body['kind'] as String,
            parentRevisionId: body['parentRevisionId'] as String?,
            dayKey: body['dayKey'] as String?,
            occurredAtMs: body['occurredAtMs'] as int,
            tiptapJson: jsonEncode(body['document']),
            deleted: body['deleted'] as bool,
          );
          _active(isSessionActive);
          return result;
        });
        // Notifications cannot turn a committed write into an error reply.
        try {
          onCommitted?.call(topicId);
        } catch (error, stack) {
          logger.e('LAN month notification failed',
              error: error, stackTrace: stack);
        }
        await _reply(r, 200, {
          'state': 'saved_on_phone', 'syncState': 'local_only',
          'block': _block(saved),
        });
      }
    } on ModLanWriteException catch (e) {
      await _reply(r, e.status, {'error': e.code});
    } on ModMonthStoreException catch (e) {
      final status = _conflicts.contains(e.code) ? 409 :
          (e.code.startsWith('invalid_') ||
           e.code.startsWith('unsupported_') ||
           e.code == 'summary_must_not_have_day' ||
           e.code == 'revision_self_parent') ? 422 : 500;
      await _reply(r, status, {'error': e.code});
    } on TimeoutException {
      await _reply(r, 408, {'error': 'request_timeout'});
    } catch (error, stack) {
      logger.e('LAN month request failed', error: error, stackTrace: stack);
      await _reply(r, 500, {'error': 'month_request_failed_no_ack'});
    }
    return true;
  }
}
