#!/usr/bin/env python3
"""Fail-closed structural verifier for the Moodiary W9.8.4.13 safe parallel-install ARM64 APK."""
from __future__ import annotations
import hashlib
import json
import os
import struct
import sys
import zipfile
from pathlib import Path

EXPECTED_PACKAGE = "cn.yooss.moodiary.v3safe"
EXPECTED_VERSION_NAME = "2.9.4"
EXPECTED_VERSION_CODE = 126
EXPECTED_MIN_SDK = 28
EXPECTED_TARGET_SDK = 36
OLD_PARALLEL_PACKAGE = "cn.yooss.moodiary.v3dev"
PREVIOUS_DEV_SIGNER_SHA256 = (
    "19a9a5816297abfac1daaba0fbeeeedfd5bc8a67aa42e479aa60a3534c880b3a"
)

def u16(data: bytes, offset: int) -> int:
    return struct.unpack_from("<H", data, offset)[0]

def u32(data: bytes, offset: int) -> int:
    return struct.unpack_from("<I", data, offset)[0]

def length8(data: bytes, offset: int) -> tuple[int, int]:
    value = data[offset]
    offset += 1
    if value & 0x80:
        value = ((value & 0x7f) << 8) | data[offset]
        offset += 1
    return value, offset

def length16(data: bytes, offset: int) -> tuple[int, int]:
    value = u16(data, offset)
    offset += 2
    if value & 0x8000:
        value = ((value & 0x7fff) << 16) | u16(data, offset)
        offset += 2
    return value, offset

def parse_manifest(xml: bytes) -> tuple[dict, dict]:
    if len(xml) < 8 or u16(xml, 0) != 0x0003:
        raise SystemExit("APK AndroidManifest.xml is not binary XML")
    strings: list[str] = []
    manifest: dict = {}
    sdk: dict = {}
    pos = 8
    while pos < len(xml):
        kind, header, size = struct.unpack_from("<HHI", xml, pos)
        if size < header or size == 0 or pos + size > len(xml):
            raise SystemExit("Malformed Android binary XML chunk")
        if kind == 0x0001:
            count = u32(xml, pos + 8)
            flags = u32(xml, pos + 16)
            start = u32(xml, pos + 20)
            for index in range(count):
                offset = pos + start + u32(xml, pos + header + index * 4)
                if flags & 0x100:
                    _, offset = length8(xml, offset)
                    length, offset = length8(xml, offset)
                    strings.append(xml[offset:offset + length].decode("utf-8"))
                else:
                    length, offset = length16(xml, offset)
                    strings.append(xml[offset:offset + length * 2].decode("utf-16le"))
        elif kind == 0x0102:
            name_index = u32(xml, pos + 20)
            if name_index >= len(strings):
                raise SystemExit("Android manifest element name is invalid")
            element = strings[name_index]
            attr_start = u16(xml, pos + 24)
            attr_size = u16(xml, pos + 26)
            count = u16(xml, pos + 28)
            attrs = {}
            for index in range(count):
                attr_pos = pos + 16 + attr_start + index * attr_size
                key_index = u32(xml, attr_pos + 4)
                raw_index = u32(xml, attr_pos + 8)
                data_type = xml[attr_pos + 15]
                value = u32(xml, attr_pos + 16)
                if key_index >= len(strings):
                    raise SystemExit("Android manifest attribute name is invalid")
                key = strings[key_index]
                if raw_index != 0xffffffff:
                    if raw_index >= len(strings):
                        raise SystemExit("Android manifest raw value is invalid")
                    attrs[key] = strings[raw_index]
                elif data_type == 3:
                    if value >= len(strings):
                        raise SystemExit("Android manifest string value is invalid")
                    attrs[key] = strings[value]
                else:
                    attrs[key] = value
            if element == "manifest":
                manifest = attrs
            elif element == "uses-sdk":
                sdk = attrs
        pos += size
    if not manifest or not sdk:
        raise SystemExit("APK manifest or uses-sdk declaration is missing")
    return manifest, sdk

def parse_v2_signer_certificate_sha256(raw: bytes) -> tuple[list[str], str]:
    eocd = raw.rfind(b"PK\x05\x06")
    if eocd < 0 or eocd + 22 > len(raw):
        raise SystemExit("APK ZIP end-of-central-directory is missing")
    central_directory = u32(raw, eocd + 16)
    if central_directory < 24 or raw[central_directory - 16:central_directory] != b"APK Sig Block 42":
        raise SystemExit("APK signing block is missing")
    block_size = struct.unpack_from("<Q", raw, central_directory - 24)[0]
    pos = central_directory - block_size
    ids: list[str] = []
    signer_sha256 = None
    while pos < central_directory - 24:
        pair_size = struct.unpack_from("<Q", raw, pos)[0]
        pos += 8
        if pair_size < 4 or pos + pair_size > central_directory - 24:
            raise SystemExit("Malformed APK signing-block pair")
        algorithm_id = u32(raw, pos)
        value = raw[pos + 4:pos + pair_size]
        pos += pair_size
        ids.append(hex(algorithm_id))
        if algorithm_id == 0x7109871a:
            def lp(data: bytes, offset: int) -> tuple[bytes, int]:
                length = u32(data, offset)
                start = offset + 4
                end = start + length
                if end > len(data):
                    raise SystemExit("Malformed APK v2 signer length prefix")
                return data[start:end], end
            signers, _ = lp(value, 0)
            signer, _ = lp(signers, 0)
            signed_data, _ = lp(signer, 0)
            _, offset = lp(signed_data, 0)
            certificates, _ = lp(signed_data, offset)
            certificate, _ = lp(certificates, 0)
            signer_sha256 = hashlib.sha256(certificate).hexdigest()
    if "0x7109871a" not in ids or not signer_sha256:
        raise SystemExit("APK v2 signing scheme or signer certificate is missing")
    return ids, signer_sha256

def main() -> None:
    if len(sys.argv) != 2:
        raise SystemExit("Usage: verify_apk.py <app-v3safe-release.apk>")
    expected_signer = os.environ.get("MOODIARY_SAFE_CERT_SHA256", "").replace(":", "").strip().lower()
    if len(expected_signer) != 64 or any(c not in "0123456789abcdef" for c in expected_signer):
        raise SystemExit("MOODIARY_SAFE_CERT_SHA256 is missing or malformed; refusing unsigned/unpinned delivery")
    apk = Path(sys.argv[1])
    if not apk.is_file() or apk.stat().st_size == 0:
        raise SystemExit("APK file is missing or empty")
    raw = apk.read_bytes()
    digest = hashlib.sha256(raw).hexdigest()
    try:
        with zipfile.ZipFile(apk) as archive:
            bad_member = archive.testzip()
            if bad_member:
                raise SystemExit("APK ZIP CRC failure: " + bad_member)
            names = archive.namelist()
            abis = sorted({
                name.split("/")[1]
                for name in names
                if name.startswith("lib/") and len(name.split("/")) > 2
            })
            if abis != ["arm64-v8a"]:
                raise SystemExit("Expected ARM64-only APK; found ABIs: " + repr(abis))
            if not any(name.startswith("lib/arm64-v8a/") and name.endswith(".so") for name in names):
                raise SystemExit("ARM64 native libraries are missing")
            lan_path = "assets/flutter_assets/assets/lan/lan.js"
            if lan_path not in names:
                raise SystemExit("Bundled LAN JavaScript is missing")
            lan_js = archive.read(lan_path)
            if b"/api/v3/topics" not in lan_js:
                raise SystemExit("Bundled LAN API v3 route is missing")
            editor_pages = [
                name for name in names
                if name.endswith("/assets/editor/index.html")
            ]
            if len(editor_pages) != 1:
                raise SystemExit("Expected exactly one native editor index.html")
            editor_html = archive.read(editor_pages[0])
            if b"bodyOnly" not in editor_html or b"snapshot" not in editor_html:
                raise SystemExit("Native editor snapshot/body-only assets are incomplete")
            manifest, sdk = parse_manifest(archive.read("AndroidManifest.xml"))
    except zipfile.BadZipFile as error:
        raise SystemExit("APK is not a valid ZIP container: " + str(error)) from error

    if manifest.get("package") != EXPECTED_PACKAGE:
        raise SystemExit("Unexpected APK package: " + repr(manifest.get("package")))
    if int(manifest.get("versionCode", -1)) != EXPECTED_VERSION_CODE:
        raise SystemExit("Unexpected APK versionCode: " + repr(manifest.get("versionCode")))
    if manifest.get("versionName") != EXPECTED_VERSION_NAME:
        raise SystemExit("Unexpected APK versionName: " + repr(manifest.get("versionName")))
    if int(sdk.get("minSdkVersion", -1)) != EXPECTED_MIN_SDK:
        raise SystemExit("Unexpected APK minSdkVersion: " + repr(sdk.get("minSdkVersion")))
    if int(sdk.get("targetSdkVersion", -1)) != EXPECTED_TARGET_SDK:
        raise SystemExit("Unexpected APK targetSdkVersion: " + repr(sdk.get("targetSdkVersion")))

    signing_ids, signer_sha256 = parse_v2_signer_certificate_sha256(raw)
    if signer_sha256.lower() != expected_signer:
        raise SystemExit("APK signer does not match the persistent W9.8.4.13 signing certificate")
    if manifest["package"] == OLD_PARALLEL_PACKAGE:
        raise SystemExit("Safe APK package ID collides with the old installation")
    result = {
        "path": str(apk),
        "size_bytes": len(raw),
        "sha256": digest,
        "package": manifest["package"],
        "version_code": manifest["versionCode"],
        "version_name": manifest["versionName"],
        "min_sdk": sdk["minSdkVersion"],
        "target_sdk": sdk["targetSdkVersion"],
        "abis": abis,
        "lan_api_v3_asset": True,
        "native_editor_snapshot_assets": True,
        "signing_block_ids": signing_ids,
        "signer_certificate_sha256": signer_sha256,
        "expected_safe_signer_sha256": expected_signer,
        "signer_matches_persistent_safe_key": True,
        "previous_dev_signer_sha256": PREVIOUS_DEV_SIGNER_SHA256,
        "old_parallel_package_id": OLD_PARALLEL_PACKAGE,
        "parallel_install_is_safe": manifest["package"] != OLD_PARALLEL_PACKAGE,
        "migration_method": "ordinary native ZIP only; W9 custom migration pending",
        "full_custom_migration_ready": False,
        "old_app_data_modified": False,
    }
    print(json.dumps(result, ensure_ascii=False, sort_keys=True))

if __name__ == "__main__":
    main()
