#!/usr/bin/env python3
"""Unit tests for the W9.8.4.13 parallel-install Gradle patch."""
import importlib.util
from pathlib import Path

HERE = Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location("safe_install_patch", HERE / "apply_w9_8_4_13.py")
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(MODULE)


def test_clone_v3dev_suffix_to_v3safe():
    source = '''productFlavors {
        create("production") { dimension = "channel" }
        create("v3dev") {
            dimension = "channel"
            applicationIdSuffix = ".v3dev"
        }
    }'''
    result = MODULE.ensure_v3safe_flavor(source)
    assert 'create("v3dev")' in result
    assert 'create("v3safe")' in result
    assert 'applicationIdSuffix = ".v3safe"' in result
    assert result.count('create("v3safe")') == 1


def test_patch_is_idempotent():
    source = '''productFlavors {
        create("v3dev") {
            dimension = "channel"
            applicationIdSuffix = ".v3dev"
        }
    }'''
    once = MODULE.ensure_v3safe_flavor(source)
    twice = MODULE.ensure_v3safe_flavor(once)
    assert once == twice


def test_wrong_existing_safe_identity_fails_closed():
    source = '''productFlavors {
        create("v3dev") {
            dimension = "channel"
            applicationIdSuffix = ".v3dev"
        }
        create("v3safe") {
            dimension = "channel"
            applicationIdSuffix = ".v3dev"
        }
    }'''
    try:
        MODULE.ensure_v3safe_flavor(source)
    except SystemExit as error:
        assert "unexpected applicationId" in str(error)
    else:
        raise AssertionError("wrong package identity was accepted")


def test_missing_v3dev_fails_closed():
    try:
        MODULE.ensure_v3safe_flavor('productFlavors { create("production") {} }')
    except SystemExit as error:
        assert "exactly one" in str(error)
    else:
        raise AssertionError("missing baseline flavor was accepted")


def test_version_bump_is_idempotent():
    assert MODULE.ensure_safe_version("version: 2.9.2+124\n") == "version: 2.9.3+125\n"
    assert MODULE.ensure_safe_version("version: 2.9.3+125\n") == "version: 2.9.3+125\n"


if __name__ == "__main__":
    tests = [
        test_clone_v3dev_suffix_to_v3safe,
        test_patch_is_idempotent,
        test_wrong_existing_safe_identity_fails_closed,
        test_missing_v3dev_fails_closed,
        test_version_bump_is_idempotent,
    ]
    for test in tests:
        test()
        print("PASS:", test.__name__)
    print(f"All {len(tests)} safe-install patch tests passed")
