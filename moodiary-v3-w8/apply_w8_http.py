"""W8.4 staged HTTP-image upload integration after W7, fail closed.

Never enables rich image nodes or writes attachments to Diary. All staged
files are owned by the paired session and are deleted on revoke/stop.
"""
from pathlib import Path
import sys

root=Path(sys.argv[1]).resolve() if len(sys.argv)>1 else Path.cwd()
here=Path(__file__).resolve().parent
source=here/"overlay/mobile/lib/app/home/mod_lan_image_http.dart"
target=root/"mobile/lib/app/home/mod_lan_image_http.dart"
if not source.exists() or target.exists():
    raise SystemExit("W8.4 HTTP file missing or target already exists")
target.parent.mkdir(parents=True,exist_ok=True)
target.write_bytes(source.read_bytes())

p=root/"mobile/lib/app/home/mod_lan_service.dart"
s=p.read_text(encoding="utf-8")
def one(old,new):
    global s
    n=s.count(old)
    if n!=1:
        raise SystemExit(f"W8.4 server anchor changed: {n} matches: {old[:85]!r}")
    s=s.replace(old,new,1)

one(
"import 'package:moodiary_di/moodiary_di.dart';",
"import 'package:moodiary_di/moodiary_di.dart';\nimport 'package:moodiary_files/moodiary_files.dart';")
one(
"import 'mod_lan_rich.dart';",
"""import 'mod_lan_rich.dart';
import 'mod_lan_image_policy.dart';
import 'mod_lan_image_staging.dart';
import 'mod_lan_image_decoder.dart';
import 'mod_lan_image_http.dart';""")
one(
"  ModLanRichWriter get _richWriter => ModLanRichWriter(getIt<DiaryRepository>());",
"""  ModLanRichWriter get _richWriter => ModLanRichWriter(getIt<DiaryRepository>());
  ModLanImageStaging? _staging;
  Future<void> _revokeImageSessions() async {
    final staging = _staging;
    if (staging == null) return;
    for (final sessionId in _sessions.keys.toList()) {
      await staging.revokeSession(sessionId);
    }
  }""")
one(
"    final ip = await _wifiAddress();",
"""    final ip = await _wifiAddress();
    // Private, dedicated temporary workspace. Delete any old uncommitted
    // drafts left by an unexpected previous process termination.
    final uploadRoot = Directory(AppFiles.getRealPath('lan-staging', ''));
    if (await uploadRoot.exists()) await uploadRoot.delete(recursive: true);
    _staging = ModLanImageStaging(
      privateCacheRoot: uploadRoot,
      verifyDecodedImage: modLanVerifyDecodedImage,
    );""")
one(
"    _pairs.clear();\n    _closeWebSockets();",
"""    _pairs.clear();
    // Cancel browser sessions first, then close HTTP streams before cleaning.
    unawaited(_revokeImageSessions());
    _closeWebSockets();""")
one(
"    await server?.close(force: true);\n    await _hub.close();",
"""    await server?.close(force: true);
    final staging = _staging;
    _staging = null;
    if (staging != null) {
      // A stream may be winding down after the connection was force-closed.
      // Retry graceful cleanup briefly; every unfinished accept also deletes
      // its own private temporary directory when the stream terminates.
      for (var tries = 0; tries < 20; tries++) {
        try {
          await staging.close();
          break;
        } on ModLanImagePolicyException {
          if (tries == 19) break;
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
      }
    }
    await _hub.close();""")
one(
"    _closeWebSockets();\n    _sessions.clear(); // W1-W3: only one authorized browser at a time.",
"""    unawaited(_revokeImageSessions());
    _closeWebSockets();
    _sessions.clear(); // Only one authorized browser at a time.""")
one(
"  void revokeAll() {\n    _closeWebSockets();",
"""  void revokeAll() {
    unawaited(_revokeImageSessions());
    _closeWebSockets();""")
one(
"      _sessions.remove(cookie.value);\n      connections.value = _sessions.length;",
"""      _sessions.remove(cookie.value);
      final staging = _staging;
      if (staging != null) {
        unawaited(staging.revokeSession(cookie.value));
      }
      connections.value = _sessions.length;""")
one(
"        if (r.method == 'POST' && path == '/api/rich/diaries') {",
"""        if (r.method == 'POST' && path == '/api/media/staged') {
          final staging = _staging;
          if (staging == null) {
            throw const ModLanImagePolicyException(503, 'upload_service_stopped');
          }
          final uploaded = await ModLanImageHttp.accept(
            request: r, authorizedSessionId: session.id, staging: staging);
          if (_stopping || !identical(_sessions[session.id], session)) {
            await staging.revokeSession(session.id);
            throw const ModLanImagePolicyException(401, 'pairing_required');
          }
          await _json(r, HttpStatus.created, {
            'id': uploaded.id,
            'mime': uploaded.mime,
            'size': uploaded.size,
            'sha256': uploaded.sha256Hex,
            'expiresAt': uploaded.expiresAt.toIso8601String(),
            'state': 'staged_not_attached',
          });
        } else if (r.method == 'POST' && path == '/api/rich/diaries') {""")
one(
"""      } on ModLanWriteException catch (e) {
        await _json(r, e.status, {'error': e.code});
      } on FormatException {""",
"""      } on ModLanImagePolicyException catch (e) {
        await _json(r, e.status, {'error': e.code});
      } on ModLanWriteException catch (e) {
        await _json(r, e.status, {'error': e.code});
      } on FormatException {""")

p.write_text(s,encoding="utf-8")
print("W8.4: authenticated upload-to-staging route installed; diary media writes remain disabled")
