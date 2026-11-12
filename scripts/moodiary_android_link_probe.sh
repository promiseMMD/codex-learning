#!/system/bin/sh
set -eu
ROOT="/data/local/tmp/moodiary-link-probe-$$"
mkdir -p "$ROOT/stage" "$ROOT/out"
trap 'rm -rf "$ROOT"' EXIT
printf 'verified candidate payload\n' > "$ROOT/stage/source.zip"
printf 'different payload\n' > "$ROOT/stage/other.zip"
# Invoke the same external command name as Dart Process.run('link').
if ! command -v link >/dev/null 2>&1; then
  echo 'BLOCKED: Android does not expose external link command' >&2
  exit 21
fi
link "$ROOT/stage/source.zip" "$ROOT/out/candidate.zip"
cmp "$ROOT/stage/source.zip" "$ROOT/out/candidate.zip"
if link "$ROOT/stage/other.zip" "$ROOT/out/candidate.zip"; then
  echo 'FAIL: existing final path was replaced' >&2
  exit 22
fi
cmp "$ROOT/stage/source.zip" "$ROOT/out/candidate.zip"
ln -s "$ROOT/out/missing.zip" "$ROOT/out/dangling.zip"
if link "$ROOT/stage/other.zip" "$ROOT/out/dangling.zip"; then
  echo 'FAIL: dangling symlink was replaced' >&2
  exit 23
fi
test -L "$ROOT/out/dangling.zip"
test ! -e "$ROOT/out/missing.zip"
cmp "$ROOT/stage/source.zip" "$ROOT/out/candidate.zip"
echo 'PASS: emulator shell link and no-clobber behavior'
