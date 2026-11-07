"""W8.5 CAS-guarded native image attach, after W8.4 HTTP staging.

The initial API can append ONE validated image to a supported ordinary rich
Diary. It deliberately does not unlock W6 arbitrary rich-image updates, nor
does it modify long-term/monthly records.
"""
from pathlib import Path
import shutil
import sys

root=Path(sys.argv[1]).resolve() if len(sys.argv)>1 else Path.cwd()
here=Path(__file__).resolve().parent
for rel in [
  "mobile/lib/app/home/mod_lan_image_attach.dart",
  "mobile/test/mod_lan_image_attach_test.dart",
]:
    source=here/"overlay"/rel
    target=root/rel
    if target.exists() or not source.is_file():
        raise SystemExit(f"W8.5 file collision or source missing: {rel}")
    target.parent.mkdir(parents=True,exist_ok=True)
    shutil.copyfile(source,target)

p=root/"mobile/lib/app/home/mod_lan_service.dart"
s=p.read_text(encoding="utf-8")
def one(a,b):
    global s
    n=s.count(a)
    if n!=1:
        raise SystemExit(f"W8.5 server API anchor drift: {n}, {a[:90]!r}")
    s=s.replace(a,b,1)

one("import 'mod_lan_image_policy.dart';",
    "import 'mod_lan_image_policy.dart';\nimport 'mod_lan_image_attach.dart';")

one(
"    if (r.method == 'POST' && path == '/api/media/staged') {",
"""    if (r.method == 'POST' && path.startsWith('/api/media/attach/') &&
        r.uri.pathSegments.length == 4) {
      // Same-origin and phone session approval were already verified.
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
        final input = await _readJson(r);
        final stageId = input['stagingId'];
        final revision = input['revision'];
        if (stageId is! String || revision is! String) {
          throw const ModLanImagePolicyException(
            422, 'invalid_image_attach_request',
          );
        }
        // This check is necessary after request-body parsing; the phone may
        // have revoked the session while the network request was in flight.
        if (_sessions[session.id] != session || staging != _imageStaging) {
          throw const ModLanImagePolicyException(403, 'session_revoked');
        }
        final writer = ModLanImageAttach(
          repository: getIt<DiaryRepository>(),
          staging: staging,
          isSessionActive: () =>
              _sessions[session.id] == session && _imageStaging == staging,
        );
        final updated = await writer.appendStagedImage(
          diaryId: r.uri.pathSegments[3],
          stageId: stageId,
          ownerSession: session.id,
          revision: revision,
        );
        // Only now can the browser report 'saved to phone'.
        await _json(r, HttpStatus.ok, {
          'state': 'saved_on_phone',
          'diaryId': updated.id,
          'revision': ModLanWriteSafety.revision(updated),
          'imageName': updated.imageName.last,
        });
      } on ModLanWriteException catch (e) {
        await _json(r, e.status, {'error': e.code});
      } on ModLanImagePolicyException catch (e) {
        await _json(r, e.status, {'error': e.code});
      } catch (_) {
        await _json(r, HttpStatus.internalServerError,
            {'error': 'image_attach_failed'});
      }
      return;
    }
    if (r.method == 'POST' && path == '/api/media/staged') {"""
)
p.write_text(s,encoding="utf-8")
print("W8.5 CAS-protected append-image API installed; W7 UI remains read-only for image diaries.")
