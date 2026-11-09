#!/usr/bin/env python3
"""CI tiering contract (stdlib only); regression tests remain immutable gates."""
from pathlib import Path
import ast
import re
ROOT=Path(__file__).resolve().parents[1]
fast=(ROOT/".github/workflows/moodiary-v3-fast-ci.yml").read_text()
full=(ROOT/".github/workflows/moodiary-v3-full-ci.yml").read_text()
release=(ROOT/".github/workflows/moodiary-v3-release.yml").read_text()
prepare=(ROOT/"moodiary-ci/prepare-workspace.sh").read_text()

def require(source, value, label):
    if value not in source:
        raise SystemExit("CI contract missing "+label+": "+value)

# Do not disable sqlite3's supply-chain SHA check on release builds.
# Only the temporary test pubspec opts into the OS SQLite installation.
for source in (fast, full):
    require(source, "sqlite3: {source: system}", "Linux-test SQLite hook")
require(full, "cp /tmp/moodiary-w9-test-pubspec.yaml pubspec.yaml",
        "restore signed APK hook settings")

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
  "sha256sum --check app-v3dev-release.apk.sha256",
  "BUILD-PROVENANCE.txt","retention-days: 90"):
    require(full,needle,"complete regression")

for needle in ("refs/heads/main","environment: android-device-qa",
  "tested_sha","tested_apk_sha256","qa_evidence",
  "sha256sum --check app-v3dev-release.apk.sha256",
  'test "$TESTED_SHA" = "$GITHUB_SHA"',
  'test "$TESTED_APK_SHA256" = "$actual_sha"'):
    require(release,needle,"Android release gate")

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
  "moodiary-v3-w9-8-4-9/apply_w9_8_4_9.py"):
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

print("All CI contracts verified: quick, full coverage, APK SHA and device QA")
