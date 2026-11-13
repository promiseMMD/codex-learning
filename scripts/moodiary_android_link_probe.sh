#!/system/bin/sh
set -eu
ROOT="/data/local/tmp/moodiary-link-probe-$$"
mkdir -p "$ROOT/stage" "$ROOT/out"
trap 'rm -rf "$ROOT"' EXIT
printf 'verified candidate payload\n' > "$ROOT/stage/source.zip"
printf 'different payload\n' > "$ROOT/stage/other.zip"
# Android lacks external link(1). Test ln(1) without -f as a possible
# no-clobber replacement; do not change production before this passes.
if ! command -v ln >/dev/null 2>&1; then
  echo 'BLOCKED: Android does not expose ln command' >&2
  exit 21
fi
ln "$ROOT/stage/source.zip" "$ROOT/out/candidate.zip"
cmp "$ROOT/stage/source.zip" "$ROOT/out/candidate.zip"
if ln "$ROOT/stage/other.zip" "$ROOT/out/candidate.zip"; then
  echo 'FAIL: existing final path was replaced' >&2
  exit 22
fi
cmp "$ROOT/stage/source.zip" "$ROOT/out/candidate.zip"
ln -s "$ROOT/out/missing.zip" "$ROOT/out/dangling.zip"
if ln "$ROOT/stage/other.zip" "$ROOT/out/dangling.zip"; then
  echo 'FAIL: dangling symlink was replaced' >&2
  exit 23
fi
test -L "$ROOT/out/dangling.zip"
test ! -e "$ROOT/out/missing.zip"
cmp "$ROOT/stage/source.zip" "$ROOT/out/candidate.zip"
echo 'PASS: emulator shell ln and no-clobber behavior'
