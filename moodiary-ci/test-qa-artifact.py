#!/usr/bin/env python3
"""Offline regression cases for exact signed candidate APK evidence binding."""
from __future__ import annotations

import hashlib
import json
import tempfile
import unittest
from pathlib import Path
from importlib.util import module_from_spec, spec_from_file_location

SCRIPT = Path(__file__).with_name("check-qa-artifact.py")
spec = spec_from_file_location("check_qa_artifact", SCRIPT)
assert spec and spec.loader
module = module_from_spec(spec)
spec.loader.exec_module(module)

COMMIT = "a" * 40
DIGEST = "b" * 64
RUN_ID = "42776506926"


class CandidateEvidenceTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.path = Path(self.temp.name)
        self.apk = self.path / module.APK_NAME
        self.apk.write_bytes(b"unit-test-only-not-a-real-apk")
        self.sha = hashlib.sha256(self.apk.read_bytes()).hexdigest()
        self.provenance = {
            "source_commit": COMMIT,
            "workflow_run": RUN_ID,
            "workflow_ref": "refs/heads/main",
            "application_id": module.EXPECTED_PACKAGE,
            "version_code": "126",
            "version_name": "2.9.2",
            "artifact_status": module.EXPECTED_STATUS,
            "original_first_import_device_qa": "pending",
            "signer_certificate_sha256": DIGEST,
        }
        self.report = {
            "package": module.EXPECTED_PACKAGE,
            "version_code": 126,
            "version_name": "2.9.2",
            "artifact_status": module.EXPECTED_STATUS,
            "original_first_import_device_qa": "pending",
            "signer_matches_persistent_safe_key": True,
            "parallel_install_is_safe": True,
            "signer_certificate_sha256": DIGEST,
            "expected_safe_signer_sha256": DIGEST,
        }
        self.write_files()

    def write_files(self) -> None:
        (self.path / (module.APK_NAME + ".sha256")).write_text(
            f"{self.sha}  {module.APK_NAME}\n", encoding="ascii"
        )
        (self.path / "BUILD-PROVENANCE.txt").write_text(
            "\n".join(f"{k}={v}" for k, v in self.provenance.items()) + "\nversion: 2.9.2+126\n",
            encoding="utf-8",
        )
        (self.path / "APK-VERIFICATION.json").write_text(
            json.dumps(self.report), encoding="utf-8"
        )

    def verify(self, run_id: str = RUN_ID, tested_sha: str = COMMIT, current_sha: str = COMMIT) -> None:
        module.verify(self.path, run_id, tested_sha, self.sha, current_sha)

    def test_matching_evidence(self) -> None:
        self.verify()

    def test_wrong_workflow_run_is_rejected(self) -> None:
        self.provenance["workflow_run"] = "11111"
        self.write_files()
        with self.assertRaisesRegex(ValueError, "workflow_run"):
            self.verify()

    def test_wrong_build_commit_is_rejected(self) -> None:
        self.provenance["source_commit"] = "c" * 40
        self.write_files()
        with self.assertRaisesRegex(ValueError, "source_commit"):
            self.verify()

    def test_wrong_current_commit_is_rejected(self) -> None:
        with self.assertRaisesRegex(ValueError, "differs"):
            self.verify(current_sha="c" * 40)

    def test_sha256_does_not_match_actual_bytes(self) -> None:
        self.apk.write_bytes(b"substituted-apk")
        with self.assertRaisesRegex(ValueError, "APK bytes"):
            self.verify()

    def test_wrong_apk_report_package_is_rejected(self) -> None:
        self.report["package"] = "other.package"
        self.write_files()
        with self.assertRaisesRegex(ValueError, "package"):
            self.verify()

    def test_wrong_report_signer_is_rejected(self) -> None:
        self.report["signer_certificate_sha256"] = "c" * 64
        self.write_files()
        with self.assertRaisesRegex(ValueError, "signer"):
            self.verify()

    def test_candidate_is_not_a_formal_release(self) -> None:
        self.report["artifact_status"] = "formal-release"
        self.write_files()
        with self.assertRaisesRegex(ValueError, "status"):
            self.verify()

    def test_wrong_candidate_source_branch_is_rejected(self) -> None:
        self.provenance["workflow_ref"] = "refs/heads/feature"
        self.write_files()
        with self.assertRaisesRegex(ValueError, "workflow_ref"):
            self.verify()

    def test_review_branch_qa_evidence_is_accepted_without_releasing(self) -> None:
        branch_ref = "refs/heads/moodiary-v3-w9-8-4-26-signed-qa-candidate-20261110"
        self.provenance["workflow_ref"] = branch_ref
        self.write_files()
        module.verify(
            self.path, RUN_ID, COMMIT, self.sha, COMMIT, branch_ref
        )
        self.assertEqual(self.report["artifact_status"], module.EXPECTED_STATUS)

    def test_unrelated_branch_is_rejected_even_if_provenance_matches(self) -> None:
        branch_ref = "refs/heads/feature-any"
        self.provenance["workflow_ref"] = branch_ref
        self.write_files()
        with self.assertRaisesRegex(ValueError, "unsupported QA candidate branch"):
            module.verify(
                self.path, RUN_ID, COMMIT, self.sha, COMMIT, branch_ref
            )

    def test_qa_branch_cannot_fake_main_source(self) -> None:
        branch_ref = "refs/heads/moodiary-v3-w9-8-4-26-signed-qa-candidate-20261110"
        self.provenance["workflow_ref"] = branch_ref
        self.write_files()
        with self.assertRaisesRegex(ValueError, "workflow_ref"):
            self.verify()


    def test_duplicate_provenance_lines_fail_closed(self) -> None:
        with (self.path / "BUILD-PROVENANCE.txt").open("a", encoding="utf-8") as handle:
            handle.write(f"workflow_run={RUN_ID}\n")
        with self.assertRaisesRegex(ValueError, "duplicate"):
            self.verify()


if __name__ == "__main__":
    unittest.main(verbosity=2)
