"""Install the W8 image intake/decoder/staging foundation onto W7.

Only the source and test files are installed. No HTTP upload endpoint,
image-node editor write permission or WebDAV media mutation is enabled here.
"""
from pathlib import Path
import shutil
import sys

root=Path(sys.argv[1]).resolve() if len(sys.argv)>1 else Path.cwd()
here=Path(__file__).resolve().parent
files=[
  "mobile/lib/app/home/mod_lan_image_policy.dart",
  "mobile/lib/app/home/mod_lan_image_staging.dart",
  "mobile/lib/app/home/mod_lan_image_decoder.dart",
  "mobile/test/mod_lan_image_decoder_test.dart",
]
for relative in files:
    original=here/"overlay"/relative
    if not original.is_file():
        raise SystemExit("Missing W8 overlay source "+str(original))
    dest=root/relative
    if dest.exists():
        raise SystemExit("W8 destination exists; failing closed "+str(dest))
    dest.parent.mkdir(parents=True,exist_ok=True)
    shutil.copyfile(original,dest)

pub=root/"mobile/pubspec.yaml"
data=pub.read_text(encoding="utf8")
if "  crypto:" not in data:
    needle="dependencies:\n"
    if data.count(needle)!=1:
        raise SystemExit("W8 dependencies anchor no longer unique")
    data=data.replace(needle,needle+"  crypto: 3.0.6\n",1)
    pub.write_text(data,encoding="utf8")

print("W8 native staging and decoder foundation copied; HTTP image writes stay disabled")
