"""Moodiary W9.7.8: conservative official Nutstore WebDAV compatibility.

Follows historical overlays; no automatic remote data migration, retries,
folder deletion or live restore. Fail closed on ambiguous listing and uploads.
"""
from pathlib import Path
import shutil
import sys

root=Path(sys.argv[1]).resolve()
here=Path(__file__).resolve().parent
for file in (here/'overlay').rglob('*'):
    if file.is_file():
        dest=root/file.relative_to(here/'overlay')
        if dest.exists():
            raise SystemExit('Refusing overlay conflict: '+str(dest))
        dest.parent.mkdir(parents=True,exist_ok=True)
        shutil.copy2(file,dest)

backend=root/'packages/feature/moodiary_sync/lib/src/data/impl/webdav_sync.dart'
data=backend.read_text(encoding='utf-8')
def change(old,new):
    global data
    if data.count(old)!=1:
        raise SystemExit('Unexpected WebDAV implementation (anchor mismatch): '+old[:90])
    data=data.replace(old,new,1)

change("import 'dart:async';",
    "import 'dart:async';\nimport 'dart:io';")
change("import 'package:moodiary_sync/src/data/remote_lease.dart';",
    "import 'package:moodiary_sync/src/data/remote_lease.dart';"
    "\nimport 'package:moodiary_sync/src/data/nutstore_webdav_policy.dart';")
change("  static bool _ready(List<String> o) =>\n"
       "      _at(o, 0).isNotEmpty && _at(o, 1).isNotEmpty;",
       "  static bool _ready(List<String> o) =>\n"
       "      _at(o, 0).isNotEmpty && _at(o, 1).isNotEmpty &&\n"
       "      (!NutstoreWebDavPolicy.isOfficialHost(_at(o, 0)) ||\n"
       "       _at(o, 2).isNotEmpty);")
change("    await rust.FastCore.ensureInitialized();",
       "    NutstoreWebDavPolicy.requireSafeEndpoint(_at(opts, 0));\n"
       "    await rust.FastCore.ensureInitialized();")
change("      final client = await _client();\n"
       "      await client.writeObject(key: key, data: bytes);",
       "      NutstoreWebDavPolicy.guardUploadSize(\n"
       "        _at(await _read(), 0), bytes.lengthInBytes);\n"
       "      final client = await _client();\n"
       "      await client.writeObject(key: key, data: bytes);")
change("      final client = await _client();\n"
       "      await client.writeObjectFile(key: key, filePath: filePath);",
       "      NutstoreWebDavPolicy.guardUploadSize(\n"
       "        _at(await _read(), 0), await File(filePath).length());\n"
       "      final client = await _client();\n"
       "      await client.writeObjectFile(key: key, filePath: filePath);")
change("      final client = await _client();\n"
       "      return await client.listObjects();",
       "      final client = await _client();\n"
       "      final objects = await client.listObjects();\n"
       "      NutstoreWebDavPolicy.guardObjectListing(\n"
       "        _at(await _read(), 0), objects.length);\n"
       "      return objects;")
change("  Future<void> saveOptions(List<String> options) async {\n"
       "    await _config.save(options);",
       "  Future<void> saveOptions(List<String> options) async {\n"
       "    if (options.isNotEmpty) {\n"
       "      NutstoreWebDavPolicy.requireSafeEndpoint(options.first);\n"
       "    }\n"
       "    await _config.save(options);")
backend.write_text(data,encoding='utf-8')

form=root/'packages/feature/moodiary_sync/lib/src/presentation/widget/webdav_form_sheet.dart'
ui=form.read_text(encoding='utf-8')
anchor="import 'package:moodiary_sync/src/data/model/sync_provider.dart';"
if ui.count(anchor)!=1:
    raise SystemExit('Unexpected WebDAV settings form')
ui=ui.replace(anchor,anchor+"\nimport 'package:moodiary_sync/src/data/nutstore_webdav_policy.dart';")
old="        : null;\n    final userError = _userCtl.text.trim().isEmpty"
new=("        : NutstoreWebDavPolicy.isOfficialHost(url) &&\n"
     "              !NutstoreWebDavPolicy.isSupportedEndpoint(url)\n"
     "          ? '坚果云必须使用官方 HTTPS /dav/ 地址，不要在网址中放密码'\n"
     "          : null;\n"
     "    final userError = _userCtl.text.trim().isEmpty")
if ui.count(old)!=1:
    raise SystemExit('Unexpected WebDAV URL validation form')
ui=ui.replace(old,new)
form.write_text(ui,encoding='utf-8')
print('W9.7.8 Nutstore URL, listing and file-size guards applied')
