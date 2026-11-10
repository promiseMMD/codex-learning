#!/usr/bin/env python3
"""CI tiering contract (stdlib only); regression tests remain immutable gates."""
from pathlib import Path
import ast
import re
import subprocess
ROOT=Path(__file__).resolve().parents[1]
fast=(ROOT/".github/workflows/moodiary-v3-fast-ci.yml").read_text()
full=(ROOT/".github/workflows/moodiary-v3-full-ci.yml").read_text()
release=(ROOT/".github/workflows/moodiary-v3-release.yml").read_text()
prepare=(ROOT/"moodiary-ci/prepare-workspace.sh").read_text()
# Catch duplicate YAML root keys before GitHub Actions rejects a workflow.
# A repeated permissions: block once prevented any CI job from starting.
# This is deliberately small and stdlib-only; GitHub still validates full YAML.
for workflow_name, workflow_text in (
    ("fast", fast), ("full", full), ("android-QA", release)
):
    root_keys = []
    for line in workflow_text.splitlines():
        if line.startswith((" ", "\t", "#")) or not line:
            continue
        match = re.match(r"^([A-Za-z_][A-Za-z0-9_-]*):(?:[ \t]|$)", line)
        if match:
            key = match.group(1)
            if key in root_keys:
                raise SystemExit(
                    f"Duplicate YAML root key {key!r} in {workflow_name} workflow"
                )
            root_keys.append(key)
    for expected in ("on", "permissions", "jobs"):
        if expected not in root_keys:
            raise SystemExit(
                f"Missing YAML root key {expected!r} in {workflow_name} workflow"
            )


def require(source, value, label):
    if value not in source:
        raise SystemExit("CI contract missing "+label+": "+value)

# Do not disable sqlite3's supply-chain SHA check on release builds.
# Only the temporary test pubspec opts into the OS SQLite installation.
for source in (fast, full):
    require(source, "sqlite3: {source: system}", "Linux-test SQLite hook")
require(full, "cp /tmp/moodiary-w9-test-pubspec.yaml pubspec.yaml",
        "restore signed APK hook settings")
if re.search(r"(?m)^concurrency:\s*$", fast):
    raise SystemExit("Fast push cancellation must not be workflow-scoped")
require(fast, """  fast:
    concurrency:
      group: moodiary-fast-${{ github.ref }}-${{ github.event_name }}
      cancel-in-progress: ${{ github.event_name == 'push' }}""", "fast-job-only push cancellation")
require(full, "cancel-in-progress: false", "Full Acceptance must survive later pushes")

for needle in ("flutter build apk","setup-ndk@","rustup toolchain install",
               "cargo-about@","Actual Chromium PC and mobile-width editor acceptance"):
    if needle in fast:
        raise SystemExit("Fast CI must remain lightweight: "+needle)

for needle in ("moodiary-ci/prepare-workspace.sh",
  "test/mod_lan_policy_test.dart","test/mod_continuous_safety_test.dart",
  "test/editor_snapshot_test.dart","test/sync/data/mod_month_recovery_slot_v1_test.dart",
  "test/sync/data/mod_month_isolated_restore_v1_test.dart",
  "test/sync/data/mod_month_orphan_inspector_v1_test.dart",
  "test/sync/data/mod_nutstore_webdav_policy_test.dart",
  "test/sync/data/harness/real_sigkill_orchestrator.dart",
  "test/mod_month_migration_test.dart",
  "steps.changed.outputs.data_risk == 'true'",
  "github.event_name == 'pull_request'","refs/heads/main","refs/heads/integration",
  "[full-ci]","[apk-ci]","build_apk: false","build_apk: true"):
    require(fast,needle,"quick routing")

for source in (fast, full):
    require(source, "test/mod_day_map_test.dart", "W9.8 daily mapping safety regression")
    for target in ("test/mod_day_home_index_test.dart", "test/mod_day_home_panel_test.dart"):
        require(source, target, "W9.8.2 home card safety and widget regressions")

for source in (fast, full):
    require(source, "test/mod_month_graph_archive_v2_test.dart", "V2 graph and isolated recovery regression")
    require(source, "test/sync/data/mod_month_isolated_restore_v2_test.dart", "V2 ZIP cold recovery and media integrity")
    require(source, "mod_month_zip_generation_install_v2.dart", "ZIP-to-generation-slot integration")
    require(source, "test/sync/data/mod_month_recovery_slot_v2_test.dart", "V2 generation marker and rollback safety")
    require(source, "test/sync/data/harness/real_sigkill_v2_orchestrator.dart", "actual V2 cross-process SIGKILL recovery")
    for file in ("test/sync/data/mod_month_verified_manifest_v2_test.dart", "test/sync/data/mod_month_stream_stage_v2_test.dart"):
        require(source, file, "V2 native+media backed staging and streaming integrity tests")

require(full, "cargo +1.95.0 test sync::webdav::tests --lib",
        "all Rust WebDAV tests, including Nutstore pagination-risk regression")
require(full, "moodiary-v3-w9-8-4-12/verify_apk.py", "W9.8.4.13 safe APK structural verification")
require(full, "verify --verbose --print-certs", "W9.8.4.13 cryptographic APK signature verification")
require(full, '"$apksigner"', "W9.8.4.13 Android apksigner binary")
require(full, "dump badging", "W9.8.4.13 Android package manifest verification")
require(full, '"$aapt"', "W9.8.4.13 Android aapt binary")
require(full, "versionCode='126' versionName='2.9.2'", "W9.8.4.13 exact safe app version")
require(full, "MOODIARY_SAFE_CERT_SHA256", "W9.8.4.13 pinned persistent signer")
require(full, "cn.yooss.moodiary.v3safe", "W9.8.4.13 parallel package identity")
w98413=(ROOT/"moodiary-v3-w9-8-4-12/verify_apk.py").read_text()
for needle in ("cn.yooss.moodiary.v3safe", "cn.yooss.moodiary.v3dev",
  "2.9.2", "126", "arm64-v8a", "APK Sig Block 42", "0x7109871a",
  "assets/flutter_assets/assets/lan/lan.js", "/api/v3/topics", "bodyOnly",
  "snapshot", "minSdkVersion", "targetSdkVersion", "MOODIARY_SAFE_CERT_SHA256"):
    require(w98413,needle,"W9.8.4.13 safe APK identity, signer, asset and ABI verifier")

for needle in ("workflow_call:","build_apk:","moodiary-ci/prepare-workspace.sh",
  "Actual Chromium PC and mobile-width editor acceptance",
  "test/mod_month_migration_test.dart","test/mod_month_graph_archive_v1_test.dart",
  "test/sync/data/mod_month_archive_gate_test.dart",
  "test/sync/data/mod_month_verified_manifest_v1_test.dart",
  "test/sync/data/mod_month_stream_stage_v1_test.dart",
  "test/sync/data/mod_month_zip_bundle_v1_test.dart",
  "test/sync/data/mod_month_isolated_restore_v1_test.dart",
  "test/sync/data/mod_month_recovery_slot_v1_test.dart",
  "test/sync/data/mod_month_orphan_inspector_v1_test.dart",
  "test/sync/data/mod_nutstore_webdav_policy_test.dart",
  "test/sync/data/harness/real_sigkill_orchestrator.dart",
  "MOODIARY_CRASH_MATRIX: full",
  "test/mod_lan_database_cas_test.dart","test/mod_lan_month_http_test.dart",
  "test/mod_month_store_test.dart","test/editor_snapshot_test.dart",
  "test/mod_continuous_safety_test.dart","if: $" + "{{ inputs.build_apk }}",
  "sha256sum --check app-v3safe-release.apk.sha256",
  "BUILD-PROVENANCE.txt","retention-days: 90"):
    require(full,needle,"complete regression")

for needle in ("refs/heads/main","environment: android-device-qa",
  "tested_sha","tested_apk_sha256","qa_evidence", "qa_candidate_run_id",
  "run-id: ${{ inputs.qa_candidate_run_id }}",
  "github-token: ${{ github.token }}",
  "source_commit=$TESTED_SHA",
  "artifact_status=signed-QA-candidate-not-formal-release",
  "original_first_import_device_qa=pending",
  "sha256sum --check app-v3safe-release.apk.sha256",
  'test "$TESTED_SHA" = "$GITHUB_SHA"',
  'test "$TESTED_APK_SHA256" = "$actual_sha"'):
    require(release,needle,"Android release gate")
if "release-candidate-build:" in release or "build_apk: true" in release:
    raise SystemExit("QA evidence must verify the previously installed APK, not rebuild another APK")

for needle in ("git checkout 2c552ddd7939a054122380397fb914cf000824b0",
  "modkit/verify_patch.py","modkit/apply_v3_patch.py",
  "moodiary-v3-w9-7-4/apply_w9_7_4.py",
  "moodiary-v3-w9-7-5/apply_w9_7_5.py",
  "moodiary-v3-w9-7-6/apply_w9_7_6.py",
  "moodiary-v3-w9-7-7/apply_w9_7_7.py",
  "moodiary-v3-w9-7-7-2/apply_w9_7_7_2.py",
  "moodiary-v3-w9-7-7-4/apply_w9_7_7_4.py",
  "moodiary-v3-w9-7-8/apply_w9_7_8.py",
  "moodiary-v3-w9-7-8-3/apply_w9_7_8_3.py",
  "moodiary-v3-w9-7-8-4/apply_w9_7_8_4.py",
  "moodiary-v3-w9-8-1/apply_w9_8_1.py",
  "moodiary-v3-w9-8-2/apply_w9_8_2.py",
  "moodiary-v3-w9-8-3/apply_w9_8_3.py",
  "moodiary-v3-w9-8-4-1/apply_w9_8_4_1.py",
  "moodiary-v3-w9-8-4-2/apply_w9_8_4_2.py",
  "moodiary-v3-w9-8-4-3/apply_w9_8_4_3.py",
  "moodiary-v3-w9-8-4-4/apply_w9_8_4_4.py",
  "moodiary-v3-w9-8-4-5/apply_w9_8_4_5.py",
  "moodiary-v3-w9-8-4-6/apply_w9_8_4_6.py",
  "moodiary-v3-w9-8-4-7/apply_w9_8_4_7.py",
  "moodiary-v3-w9-8-4-8/apply_w9_8_4_8.py",
  "moodiary-v3-w9-8-4-9/apply_w9_8_4_9.py",
  "moodiary-v3-w9-8-4-10/apply_w9_8_4_10.py",
  "moodiary-v3-w9-8-4-11/apply_w9_8_4_11.py",
  "moodiary-v3-w9-8-4-13/apply_w9_8_4_13.py"):
    require(prepare,needle,"pinned source assembly")
w9845=(ROOT/"moodiary-v3-w9-8-4-5/apply_w9_8_4_5.py").read_text()
for needle in (
  "ZIP-to-generation refuses an existing preview without modifying it",
  "ZIP-to-generation removes preview when restore checkpoint fails before promotion",
  "ZIP-to-generation rolls back an interrupted copy and preserves the previous generation",
  "ZIP-to-generation commits after pointer-write interruption and retains the previous generation",
  "ZIP-to-generation refuses duplicate generation IDs without overwriting existing data"):
    require(w9845,needle,"W9.8.4.5 ZIP-to-generation failure-path coverage")

w9846=(ROOT/"moodiary-v3-w9-8-4-6/apply_w9_8_4_6.py").read_text()
for needle in (
  "ZIP-to-generation protects foreign files added during the handoff",
  "ZIP-to-generation rejects replaced symlink preview without deleting user data",
  "ZIP-to-generation rejects modified media before cleanup"):
    require(w9846,needle,"W9.8.4.6 preview ownership regression")
preview_source=(ROOT/"moodiary-v3-w9-8-4-6/overlay/packages/feature/moodiary_sync/lib/src/data/mod_month_zip_generation_install_v2.dart").read_text()
for needle in ("preview_cleanup_unsafe","followLinks:false","_receipt(","_discard("):
    require(preview_source,needle,"W9.8.4.6 preview ownership guard")

w9847=(ROOT/"moodiary-v3-w9-8-4-7/apply_w9_8_4_7.py").read_text()
for needle in (
  "ZIP-to-generation refuses a preview nested inside the isolated slot root",
  "ZIP-to-generation refuses an alias through a symbolic-link parent",
  "ZIP-to-generation refuses a preview whose parent cannot be resolved"):
    require(w9847,needle,"W9.8.4.7 preview/slot path isolation tests")
preview_fence=(ROOT/"moodiary-v3-w9-8-4-7/overlay/packages/feature/moodiary_sync/lib/src/data/mod_month_zip_generation_install_v2.dart").read_text()
for needle in ("_checkPreviewIsolation(", "resolveSymbolicLinks()",
  "preview_slot_path_overlap", "preview_isolation_unverifiable"):
    require(preview_fence,needle,"W9.8.4.7 canonical preview path preflight")

w9848=(ROOT/"moodiary-v3-w9-8-4-8/apply_w9_8_4_8.py").read_text()
for needle in (
  "private workspace installs a verified isolated ZIP and reopens cleanly",
  "private workspace refuses a symlinked caller-provided root",
  "private workspace refuses forged identity before reading data",
  "private workspace never overwrites a foreign preview directory",
  "private workspace refuses archives located inside its own directory",
  "private workspace cannot reopen an unrelated path"):
    require(w9848,needle,"W9.8.4.8 private workspace acceptance")
for workflow in (fast,full):
    require(workflow,"mod_month_private_restore_workspace_v2.dart",
            "W9.8.4.8 isolated workspace source formatting")
workspace_code=(ROOT/"moodiary-v3-w9-8-4-8/overlay/packages/feature/moodiary_sync/lib/src/data/mod_month_private_restore_workspace_v2.dart").read_text()
for needle in ("createTemp(_prefix)","private_root_not_regular_directory",
   "private_workspace_identity_invalid","private_restore_archive_inside_workspace",
   "ModMonthZipGenerationInstallV2.install"):
    require(workspace_code,needle,"W9.8.4.8 private path ownership fence")

w9849=(ROOT/"moodiary-v3-w9-8-4-9/apply_w9_8_4_9.py").read_text()
for needle in (
  "Android private root preserves unrelated diaries during ZIP recovery",
  "Android private root creation is idempotent without reusing workspaces",
  "Android private root refuses an existing foreign unmarked directory",
  "Android private root refuses a symlink alias without following it",
  "Android private root refuses forged identity without altering files",
  "Android private root rejects untrusted external workspace on reopen",
  "Android private root reopen never creates missing directories",
  "Android private restore facade fails closed outside Android"):
    require(w9849,needle,"W9.8.4.9 Android private storage acceptance")
for workflow in (fast,full):
    require(workflow,"mod_month_android_restore_root_v2.dart",
            "W9.8.4.9 Android private restore binder source formatting")
app_root_code=(ROOT/"moodiary-v3-w9-8-4-9/overlay/packages/feature/moodiary_sync/lib/src/data/mod_month_android_restore_root_v2.dart").read_text()
for needle in ("PlatformService.get().applicationSupportPath",
  "Platform.isAndroid","android_restore_unsupported_platform",
  "android_restore_private_root_identity_invalid","createNewWorkspace()",
  "openExistingWorkspace(","_verifyDirectory()"):
    require(app_root_code,needle,"W9.8.4.9 trusted Android app-support root")

w98410=(ROOT/"moodiary-v3-w9-8-4-10/apply_w9_8_4_10.py").read_text()
for needle in (
  "V2 inventory is empty without any restore workspaces",
  "V2 inventory recognizes verified immutable generation without mutation",
  "V2 inventory keeps an interrupted journal without repairing it",
  "V2 inventory refuses to own unknown user files",
  "V2 inventory preserves a symlink replacing a workspace",
  "V2 inventory flags a replaced workspace identity and preserves bytes",
  "V2 inventory marks an unexpected preview for manual review",
  "V2 inventory preserves an unexpected file inside an owned workspace"):
    require(w98410,needle,"W9.8.4.10 recovery copy retention regressions")
for workflow in (fast,full):
    require(workflow,"mod_month_restore_inventory_v2.dart",
            "W9.8.4.10 restore inventory source checks")
inventory_code=(ROOT/"moodiary-v3-w9-8-4-10/overlay/packages/feature/moodiary_sync/lib/src/data/mod_month_restore_inventory_v2.dart").read_text()
for needle in ("requiresExplicitRetentionDecision","recoveryRequired",
  "unrecognized","maxEntries","followLinks:false","openExistingWorkspace("):
    require(inventory_code,needle,"W9.8.4.10 non-destructive inventory gate")

w98411=(ROOT/"moodiary-v3-w9-8-4-11/apply_w9_8_4_11.py").read_text()
root_tests=(ROOT/"moodiary-v3-w9-8-4-11/overlay/packages/feature/moodiary_sync/test/sync/data/mod_month_android_restore_root_v2_test.dart").read_text()
for needle in (
  "Android private root inspection returns null without creating a missing root",
  "Android private root inspection opens an existing verified root only",
  "Android private root inspection rejects a symlink without following it"):
    require(root_tests,needle,"W9.8.4.11 non-creating root inspection")
panel_tests=(ROOT/"moodiary-v3-w9-8-4-11/overlay/mobile/test/app/settings/recovery_inventory_panel_test.dart").read_text()
for needle in (
  "empty inventory is explicit and read-only",
  "verified copy shows measured size and opens inspection details",
  "unverified states are visible and never become cleanup actions",
  "failed inspection can be retried without changing files"):
    require(panel_tests,needle,"W9.8.4.11 recovery inventory UI acceptance")
for workflow in (fast,full):
    for path in (
      "mod_month_android_restore_root_v2_test.dart",
      "recovery_inventory_panel_test.dart",
      "recovery_inventory_panel.dart",
      "storage_page_test.dart"):
        require(workflow,path,"W9.8.4.11 read-only inventory UI and StoragePage integration coverage")
root_ui=(ROOT/"moodiary-v3-w9-8-4-11/overlay/mobile/lib/app/settings/storage/recovery_inventory_controller.dart").read_text()
panel_ui=(ROOT/"moodiary-v3-w9-8-4-11/overlay/mobile/lib/app/settings/storage/recovery_inventory_panel.dart").read_text()
require(root_ui,"openExistingRootIfPresent()","W9.8.4.11 non-creating Android root access")
require(w98411,"import 'recovery_inventory_panel.dart';","W9.8.4.11 StoragePage panel import")
require(w98411,"if (Platform.isAndroid) const RecoveryInventoryPanel(),","W9.8.4.11 Android-only StoragePage integration")
for forbidden in ("createOrOpenForSupport(", "createNewWorkspace(", ".recover(", ".delete(",
                  "restoreZipToNewIsolatedDirectory("):
    if forbidden in root_ui or forbidden in panel_ui:
        raise SystemExit("W9.8.4.11 UI must remain read-only: "+forbidden)
for needle in ("StorageScanner", "StorageCleanupKind", "storageSelectionProvider"):
    if needle in panel_ui:
        raise SystemExit("W9.8.4.11 inventory panel must not alter storage cleanup: "+needle)

# Changes to CI workflows or their gate scripts must exercise sensitive
# tests as well; otherwise a workflow-only commit can appear green while
# skipping the actual real-SIGKILL recovery test.
for needle in (r"^\.github/workflows/", r"^moodiary-ci/"):
    require(fast,needle,"CI self-modification risk routing")

# Parse embedded Python heredocs in workflow run blocks before expensive
# Flutter installation. YAML indentation must not be mistaken for Python.
for workflow_name, source in (("fast", fast), ("full", full)):
    snippets = re.findall(
        r"(?ms)^([ ]+)python3 - <<'([A-Z]+)'\s*\n(.*?)^\1\2\s*$",
        source,
    )
    if not snippets:
        raise SystemExit("Missing inline Python scripts: " + workflow_name)
    for padding, fence, raw in snippets:
        code = "\n".join(line[len(padding):] if line.startswith(padding)
                         else line for line in raw.splitlines())
        try:
            ast.parse(code)
        except SyntaxError as error:
            raise SystemExit("Broken " + workflow_name +
                             " embedded Python syntax: " + str(error))


# W9.8.4.13: old signing material is unavailable, so the new app MUST use a
# distinct package ID and a separately pinned, persistent signing certificate.
safe_patch=(ROOT/"moodiary-v3-w9-8-4-13/apply_w9_8_4_13.py").read_text()
safe_tests=(ROOT/"moodiary-v3-w9-8-4-13/test_safe_install.py").read_text()
safe_docs=(ROOT/"moodiary-v3-w9-8-4-13/SAFE-INSTALL-MIGRATION.md").read_text()
safe_keygen=(ROOT/"moodiary-v3-w9-8-4-13/generate-safe-signing-key.ps1").read_text()
safe_verifier=(ROOT/"moodiary-v3-w9-8-4-12/verify_apk.py").read_text()
release_gate=(ROOT/"moodiary-ci/check-release-readiness.py").read_text()
safe_bundle=(ROOT/"moodiary-v3-w9-8-4-2/overlay/packages/feature/moodiary_sync/lib/src/data/mod_month_zip_bundle_v2.dart").read_text()
for needle in (
  'create("v3safe")',
  'applicationIdSuffix = ".v3safe"',
  'cn.yooss.moodiary.v3safe',
  'Moodiary 安全版',
  'version: 2.9.2+125',
  'getIt<IBackupArchive>().export()',
  'getIt<IBackupArchive>().import(file.path)',
  'policy: const RestorePolicy()'):
    require(safe_patch,needle,"W9.8.4.13 safe package and migration contract")
for needle in (
  "test_clone_v3dev_suffix_to_v3safe",
  "test_patch_is_idempotent",
  "test_wrong_existing_safe_identity_fails_closed",
  "test_missing_v3dev_fails_closed",
  "test_version_bump_is_idempotent"):
    require(safe_tests,needle,"W9.8.4.13 patch regression tests")
for needle in (
  "cn.yooss.moodiary.v3dev",
  "cn.yooss.moodiary.v3safe",
  "does NOT currently",
  "mod_month_revisions",
  "not yet connected to the production",
  "Do not mark migration complete",
  "read-only",
  "keep the old app installed"):
    require(safe_docs,needle,"W9.8.4.14 truthful migration readiness contract")
for needle in (
  "This is NOT a user backup",
  "NO production restore, ZIP export",
  "No live database writes"):
    require(safe_patch,needle,"W9.8.4.14 explicit custom-data migration blocker")
require(safe_bundle,"nor is it wired to the backup UI","W9.8.4.14 offline-only ZIP boundary")
for needle in (
  "MOODIARY_SAFE_KEYSTORE_BASE64",
  "MOODIARY_SAFE_STORE_PASSWORD",
  "MOODIARY_SAFE_KEY_PASSWORD",
  "MOODIARY_SAFE_CERT_SHA256",
  "key0",
  "4096"):
    require(safe_keygen,needle,"W9.8.4.13 persistent signing-key generator")
for needle in (
  'EXPECTED_PACKAGE = "cn.yooss.moodiary.v3safe"',
  'EXPECTED_VERSION_CODE = 126',
  'EXPECTED_VERSION_NAME = "2.9.2"',
  "MOODIARY_SAFE_CERT_SHA256",
  "signer_matches_persistent_safe_key",
  "parallel_install_is_safe",
  '"artifact_status": "signed-QA-candidate-not-formal-release"',
  '"original_first_import_device_qa": "pending"'):
    require(safe_verifier,needle,"W9.8.4.14 APK identity and migration readiness report")
for needle in (
  "MOODIARY_SAFE_KEYSTORE_BASE64",
  "MOODIARY_SAFE_STORE_PASSWORD",
  "MOODIARY_SAFE_KEY_PASSWORD",
  "MOODIARY_SAFE_CERT_SHA256",
  "keytool -list",
  "flutter build apk --flavor v3safe",
  "app-v3safe-release.apk"):
    require(full,needle,"W9.8.4.13 fail-closed APK signing workflow")
require(full,"check-release-readiness.py --qa-candidate","QA-only APK build does not require circular device QA before APK exists")

# Fail fast on missing persistent signing secrets *before* installing Flutter,
# running long regressions or building an APK. This checks presence only:
# certificate/private-key identity is still checked in the original signer step.
preflight_marker = "      - name: Fail early when persistent Android signing secrets are missing"
prepare_marker = "      - name: Prepare pinned upstream and apply ALL V3 overlays"
signer_marker = "      - name: Provision persistent safe signing identity (fail closed; no debug fallback)"
if not (full.index("      - name: Validate CI safety contract before full regression")
        < full.index(preflight_marker) < full.index(prepare_marker)
        < full.index(signer_marker)):
    raise SystemExit("APK signing preflight must precede expensive full tests and keep final signer validation")
preflight_block = full[full.index(preflight_marker):full.index(prepare_marker)]
require(preflight_block,'if: ${{ inputs.build_apk }}',"only APK builds need signing preflight")
for signing_secret in (
    "MOODIARY_SAFE_KEYSTORE_BASE64", "MOODIARY_SAFE_STORE_PASSWORD",
    "MOODIARY_SAFE_KEY_PASSWORD", "MOODIARY_SAFE_CERT_SHA256",
):
    require(preflight_block, "secrets."+signing_secret, "early APK signing secret binding")
    require(preflight_block, signing_secret, "missing-secret detection")
require(preflight_block, 'if [[ -z "${!name:-}" ]]', "fail-closed missing secret check")
require(preflight_block, 'exit 1', "missing signing secret fails build")
require(full[full.index(signer_marker):],
        'The JKS certificate does not match MOODIARY_SAFE_CERT_SHA256',
        "full certificate identity verification must remain after preflight")
subprocess.run(["python3", str(ROOT/"moodiary-ci/test-signing-preflight.py")], check=True)

require(full,"signed-QA-candidate-not-formal-release","QA artifact must not imply formal release")
require(full,"original_first_import_device_qa=pending","QA artifact must declare real device acceptance pending")
require(full,'signer_certificate_sha256',"W9.8.4.14 signer parsed from verifier JSON")
require(release_gate,"MIGRATION_READY = False","production release remains fail-closed")
require(release_gate,"APK PUBLIC RELEASE BLOCKED","release guard must name correct first-migration scope")
require(release_gate,"formal Android applicationId must be explicitly approved under V1.0 D02","formal package identity must not be assumed from a QA build")
require(release_gate,"cn.yooss.moodiary.v3safe is QA-only","v3safe candidate package must not silently become the formal package")
require(release_gate,"QA CANDIDATE ONLY","QA candidate mode must not imply release")
# The user's only existing notes are in the ORIGINAL app, not a prior modded
# build. Preserve the W9 integrity tests, but do NOT require unavailable old
# modded revision history as a precondition for initial native-note migration.
require(release_gate,"original installed Moodiary version and its native backup format must be verified",
        "official original backup must be verified before releasing the modded APK")
require(release_gate,"original ZIP -> final app media, metadata and note round-trip device acceptance pending",
        "original to modded migration/device acceptance must remain fail-closed")

# V1.0 is the persistent requirements source for every future developer/chat.
spec_path = ROOT/"docs/MOODIARY_MOD_PROJECT_SPEC_V1.0.md"
if not spec_path.is_file():
    raise SystemExit("Moodiary V1.0 project requirements missing")
spec = spec_path.read_text(encoding="utf-8")
for marker, label in (
    ("B04", "upstream stable Release"),
    ("B07", "incremental Android versionCode"),
    ("C06", "first-import fidelity"),
    ("C10", "WebDAV directory separation"),
    ("C12", "database upgrade testing"),
    ("D02", "fixed app package"),
    ("D03", "persistent signing key"),
    ("D06", "device delivery acceptance"),
    ("X05", "no unapproved scope creep"),
):
    require(spec, marker, "V1.0 "+label)
require(full,"secrets:","W9.8.4.13 reusable workflow signing secret contract")
require(fast,"secrets: inherit","W9.8.4.13 safe signing secret inheritance")
if full.count("MOODIARY_SAFE_KEYSTORE_BASE64") < 2:
    raise SystemExit("APK workflow must both provision and validate persistent signing material")
subprocess.run(["python3", str(ROOT/"moodiary-v3-w9-8-4-13/test_safe_install.py")], check=True)
subprocess.run(["python3", str(ROOT/"moodiary-ci/test-release-readiness.py")], check=True)
require(release,"moodiary-ci/check-qa-artifact.py","QA gate validates exact candidate provenance")
require(release,'--candidate-run-id "$QA_CANDIDATE_RUN_ID"',"QA gate compares downloaded artifact run")
require(release,'--current-sha "$GITHUB_SHA"',"QA gate binds candidate to current code")
require((ROOT/"moodiary-ci/check-qa-artifact.py").read_text(),
        "--expected-workflow-ref", "offline QA evidence can bind to exact feature branch")
require((ROOT/"moodiary-ci/check-qa-artifact.py").read_text(),
        "signed-QA-candidate-not-formal-release", "branch QA remains candidate-only")
subprocess.run(["python3", str(ROOT/"moodiary-ci/test-qa-artifact.py")], check=True)

require(full, "upstream_commit=2c552ddd7939a054122380397fb914cf000824b0", "W9.8.4.14 latest upstream provenance")
print("All CI contracts verified: quick, full coverage, APK SHA and device QA")
