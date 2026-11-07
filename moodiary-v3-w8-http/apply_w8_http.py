"""W8.4: stage decoded images through same-origin, phone-approved HTTP.

This patch installs only a temporary image intake endpoint. It does NOT
allow a staged ID in a diary JSON document, does NOT promote media, and
does NOT report the image as synced to WebDAV. No existing notes change.
Fail closed when upstream server anchors drift.
"""
from pathlib import Path
import sys

root = Path(sys.argv[1]).resolve() if len(sys.argv)>1 else Path.cwd()
p = root/"mobile/lib/app/home/mod_lan_service.dart"
source = p.read_text(encoding="utf-8")

def patch(old,new):
    global source
    n=source.count(old)
    if n!=1:
        raise SystemExit(f"W8.4 HTTP overlay drift: expected one anchor, got {n}: {old[:95]!r}")
    source=source.replace(old,new,1)

patch(
"import 'package:moodiary_di/moodiary_di.dart';",
"""import 'package:moodiary_di/moodiary_di.dart';
import 'package:moodiary_files/moodiary_files.dart';""")
patch(
"import 'mod_lan_write.dart';",
"""import 'mod_lan_write.dart';
import 'mod_lan_image_staging.dart';
import 'mod_lan_image_decoder.dart';
import 'mod_lan_image_policy.dart';""")
patch(
"  final Map<String, _LanSession> _sessions = {};",
"""  final Map<String, _LanSession> _sessions = {};
  ModLanImageStaging? _imageStaging;

  // Only app-private cache is used, never phone public Downloads/Photos.
  static String get _imageStagingCache =>
      AppFiles.getCachePath('moodiary-v3-lan-stage');""")
patch(
"    try {\n      final server = await HttpServer.bind(ip, _port, shared: false);",
"""    try {
      final root = Directory(_imageStagingCache);
      // A previous force-stop may leave temporary bytes on disk; no staged
      // IDs are persisted across server restarts. Clean this dedicated
      // workspace before accepting new connections.
      if (await root.exists()) await root.delete(recursive: true);
      await root.create(recursive: true);
      _imageStaging = ModLanImageStaging(
        privateCacheRoot: root,
        verifyDecodedImage: modLanVerifyDecodedImage,
      );
      final server = await HttpServer.bind(ip, _port, shared: false);""")
patch(
"    } catch (_) {\n      try { await _serviceChannel.invokeMethod<void>('stop'); } catch (_) {}",
"""    } catch (_) {
      _imageStaging = null;
      try { await _serviceChannel.invokeMethod<void>('stop'); } catch (_) {}""")
patch(
"    _sessions.clear();\n    _attempts.clear();",
"""    _sessions.clear();
    final imageStaging = _imageStaging;
    _imageStaging = null;
    _attempts.clear();""")
patch(
"    await server?.close(force: true);\n    await _hub.close();",
"""    await server?.close(force: true);
    // In-flight interrupted requests are rejected by the revoked session.
    // The staging service deletes its pending files; a new start also
    // removes orphaned bytes left by abrupt process death.
    if (imageStaging != null) {
      try {
        await imageStaging.close();
      } on ModLanImagePolicyException {
        // A request is still finishing; its stream owns temporary cleanup.
        // Do not delete a directory while a stream may still write into it.
      }
    }
    await _hub.close();""")
patch(
"    _closeWebSockets();\n    _sessions.clear(); // W1-W3: only one authorized browser at a time.",
"""    _closeWebSockets();
    final oldSessionIds = _sessions.keys.toList(growable: false);
    for (final oldId in oldSessionIds) {
      unawaited(_imageStaging?.revokeSession(oldId).catchError((Object _) {}) ??
          Future<void>.value());
    }
    _sessions.clear(); // Only one authorized browser at a time.""")
patch(
"  void revokeAll() {\n    _closeWebSockets();\n    _sessions.clear();",
"""  void revokeAll() {
    _closeWebSockets();
    for (final oldId in _sessions.keys.toList()) {
      unawaited(_imageStaging?.revokeSession(oldId).catchError((Object _) {}) ??
          Future<void>.value());
    }
    _sessions.clear();""")
patch(
"    if (r.method == 'GET' && path == '/api/events') {\n      await _serveEvents(r, session);\n      return;\n    }",
"""    if (r.method == 'GET' && path == '/api/events') {
      await _serveEvents(r, session);
      return;
    }
    if (r.method == 'POST' && path == '/api/media/staged') {
      // Auth and same-origin were required above. Uploads additionally
      // require the SAME anti-CSRF proof as diary writes.
      if (r.headers.value('x-moodiary-csrf') != session.csrf) {
        await _json(r, HttpStatus.forbidden, {'error': 'csrf_required'});
        return;
      }
      final staging = _imageStaging;
      if (staging == null) {
        await _json(r, HttpStatus.serviceUnavailable,
            {'error': 'upload_service_stopped'});
        return;
      }
      try {
        final length = r.headers.contentLength;
        final uploaded = await staging.accept(
          ownerSession: session.id,
          contentType: r.headers.value(HttpHeaders.contentTypeHeader) ?? '',
          contentLength: length > 0 ? length : null,
          body: r.timeout(const Duration(seconds: 30)),
        );
        if (_sessions[session.id] != session || _imageStaging != staging) {
          await staging.revokeSession(session.id);
          await _json(r, HttpStatus.forbidden, {'error': 'session_revoked'});
          return;
        }
        // This acknowledges TEMPORARY STAGING ONLY, never a diary commit.
        await _json(r, HttpStatus.created, {
          'state': 'staged_not_attached',
          'stagingId': uploaded.id,
          'sha256': uploaded.sha256Hex,
          'size': uploaded.size,
          'mime': uploaded.mime,
          'expiresAt': uploaded.expiresAt.toIso8601String(),
        });
      } on ModLanImagePolicyException catch (error) {
        await _json(r, error.status, {'error': error.code});
      } on TimeoutException {
        await _json(r, HttpStatus.requestTimeout, {'error': 'image_timeout'});
      } catch (_) {
        await _json(r, HttpStatus.badRequest,
            {'error': 'image_upload_failed_no_ack'});
      }
      return;
    }""")
p.write_text(source,encoding="utf-8")
print("W8.4 HTTP temporary staging API installed with same-origin, CSRF, session checks")
