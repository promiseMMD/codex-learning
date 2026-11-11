#!/usr/bin/env bash
# Builds a NON-PERMANENTLY-SIGNED QA APK in the Public source repository.
# No JKS, recovery passphrase or other signing secrets are present in this job.
set -Eeuo pipefail
phase='initializing'
trap 'rc=$?; printf "::error::Public unsigned APK build failed at %s (line %s, exit %s)\n" "$phase" "$LINENO" "$rc" >&2' ERR

[[ "${GITHUB_REPOSITORY:-}" == 'promiseMMD/codex-learning' ]]
[[ "${GITHUB_REF:-}" == 'refs/heads/moodiary-v3-w9-8-4-31-permanent-application-id-20261110' ]]
[[ "${GITHUB_EVENT_NAME:-}" == 'push' ]]
source_sha="${MOODIARY_SOURCE_SHA:?Approved public source SHA is required}"
[[ "$source_sha" =~ ^[0-9a-f]{40}$ ]]
[[ "$(git rev-parse HEAD)" == "$source_sha" ]]
# Do not carry the previous Fast/Full test overrides into production builds.
[[ ! -e upstream ]]

phase='prepare-pinned-upstream-and-overlays'
echo "Build stage: ${phase}"
bash moodiary-ci/prepare-workspace.sh

phase='constrain-ephemeral-gradle-resources'
echo "Build stage: ${phase}"
python3 moodiary-ci/limit-gradle-ci.py upstream/mobile/android/gradle.properties

phase='resolve-production-flutter-dependencies'
echo "Build stage: ${phase}"
(cd upstream && flutter pub get)
phase='generate-i18n'
echo "Build stage: ${phase}"
(cd upstream/packages/foundation/moodiary_i18n && dart run slang)

phase='build-web-editor-and-lan-ui'
echo "Build stage: ${phase}"
(
  cd upstream/packages/feature_base/moodiary_editor/editor
  corepack enable
  corepack pnpm install --frozen-lockfile
  corepack pnpm exec vite build
  corepack pnpm exec vite build --config lan/vite.config.ts
)

phase='verify-qa-release-gate'
echo "Build stage: ${phase}"
python3 moodiary-ci/check-release-readiness.py --qa-candidate

phase='build-arm64-v3safe-apk-without-permanent-signer'
echo "Build stage: ${phase}"
free -h
df -h /
(cd upstream/mobile && flutter build apk --flavor v3safe --release --target-platform android-arm64)

phase='package-public-unsigned-qa'
source_apk='upstream/mobile/build/app/outputs/flutter-apk/app-v3safe-release.apk'
test -s "$source_apk"
out="${RUNNER_TEMP:?}/moodiary-public-unsigned"
mkdir -p "$out"
cp "$source_apk" "$out/app-to-sign.apk"
(
  cd "$out"
  printf 'source_sha=%s\napplication_id=cn.yooss.moodiary.v3safe\nartifact_class=unsigned-or-debug-signed-untrusted\nsource_repository=promiseMMD/codex-learning\n' "$source_sha" > SOURCE-PROVENANCE.txt
  sha256sum app-to-sign.apk > app-to-sign.apk.sha256
  sha256sum -c app-to-sign.apk.sha256
)
echo 'PASS: Public source produced a QA APK; permanent signing must occur only in the Private vault.'
