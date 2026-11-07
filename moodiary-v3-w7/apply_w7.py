"""W7: install a dedicated, bundled LAN TipTap browser workspace.

This is independent from the legacy text-only W5 UI. The PC loads static
assets embedded into the APK, on the exact phone origin. No CDN is contacted.
Write APIs continue to require pairing + anti-CSRF + database CAS.
"""
from pathlib import Path
import shutil
import sys

root=Path(sys.argv[1]).resolve() if len(sys.argv)>1 else Path.cwd()
here=Path(__file__).resolve().parent
src=here/"web"
dst=root/"packages/feature_base/moodiary_editor/editor/lan"
if dst.exists():
    raise SystemExit("W7 destination already exists: fail rather than overwrite")
shutil.copytree(src,dst)

pub=root/"mobile/pubspec.yaml"
s=pub.read_text(encoding="utf-8")
old="flutter:\n  assets:\n"
if s.count(old)!=1:
    raise SystemExit(f"W7 pubspec flutter assets section not unique: {s.count(old)}")
if "    - assets/lan/" not in s:
    s=s.replace(old,old+"    - assets/lan/\n",1)
pub.write_text(s,encoding="utf-8")

p=root/"mobile/lib/app/home/mod_lan_service.dart"
s=p.read_text(encoding="utf-8")
def replace_one(old,new):
    global s
    count=s.count(old)
    if count!=1:
        raise SystemExit(f"W7 server anchor {count} matches: {old[:90]!r}")
    s=s.replace(old,new,1)

replace_one(
"    if (r.method == 'GET' && path == '/api/events') {",
"""    // Static Tiptap app files are *only* served after phone pairing.
    // Restrict names; never construct an arbitrary filesystem path from a URL.
    if (r.method == 'GET' && path == '/lan-editor') {
      r.response.headers.set(HttpHeaders.locationHeader, '/lan-editor/');
      r.response.statusCode = HttpStatus.found;
      await r.response.close();
      return;
    }
    if (r.method == 'GET' && path == '/lan-editor/') {
      await _asset(r, await rootBundle.loadString('assets/lan/index.html'),
          'text/html; charset=utf-8');
      return;
    }
    if (r.method == 'GET' && (path == '/lan-editor/lan.js' ||
        path == '/lan-editor/lan.css' ||
        RegExp(r'^/lan-editor/lan-chunk-[a-zA-Z0-9_-]+\.js$').hasMatch(path))) {
      final name = path.split('/').last;
      await _asset(r, await rootBundle.loadString('assets/lan/$name'),
          name.endsWith('.css') ? 'text/css; charset=utf-8'
              : 'application/javascript; charset=utf-8');
      return;
    }
    if (r.method == 'GET' && path == '/api/events') {""")

replace_one(
"<section id=\"workspace\" hidden><p id=\"conn\">已连接手机</p>",
"<section id=\"workspace\" hidden><p id=\"conn\">已连接手机</p><p><a href=\"/lan-editor/\">打开 W7 Tiptap 富文本工作台（仅支持已验证的基础格式）</a></p>")
p.write_text(s,encoding="utf-8")
print("W7 LAN editor files staged; compile assets with pnpm Vite before Flutter pub get")
