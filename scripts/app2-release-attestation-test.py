#!/usr/bin/env python3
"""Regression-test the two-stage APP2 archive attestation contract."""

from __future__ import annotations

import hashlib
import importlib.util
import json
import os
import plistlib
import sys
import tempfile
from pathlib import Path


SCRIPT_DIR = Path(__file__).resolve().parent
MODULE_PATH = SCRIPT_DIR / "app2-release-attestation.py"


def fail(message: str) -> None:
    raise SystemExit(f"APP2 release attestation test failed: {message}")


def load_module() -> object:
    spec = importlib.util.spec_from_file_location("app2_release_attestation", MODULE_PATH)
    if spec is None or spec.loader is None:
        fail("cannot load the attestation module")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def json_sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def write_manifest(path: Path, approved_hash: str) -> None:
    path.write_text(
        json.dumps(
            {"approved_archive_payload_sha256": approved_hash},
            sort_keys=True,
            separators=(",", ":"),
        )
        + "\n",
        encoding="utf-8",
    )


def create_archive(root: Path) -> Path:
    archive = root / "WenxintongApp2.xcarchive"
    app = archive / "Products" / "Applications" / "WenxintongApp2.app"
    app.mkdir(parents=True)
    (archive / "Info.plist").write_bytes(
        plistlib.dumps(
            {
                "SchemeName": "BlueStoneIM-App2",
                "ApplicationProperties": {
                    "ApplicationPath": "Applications/WenxintongApp2.app"
                },
            },
            fmt=plistlib.FMT_BINARY,
            sort_keys=True,
        )
    )
    (app / "Info.plist").write_bytes(
        plistlib.dumps(
            {
                "CFBundleIdentifier": "com.wenxintong.app2",
                "CFBundleExecutable": "WenxintongApp2",
            },
            fmt=plistlib.FMT_BINARY,
            sort_keys=True,
        )
    )
    (app / "WenxintongApp2").write_bytes(b"candidate-binary")
    return archive


def expect_blocked(action: object, message: str) -> None:
    try:
        action()
    except SystemExit:
        return
    fail(message)


def main() -> None:
    module = load_module()
    if module.SCHEMA_VERSION != 5:
        fail("schema version was not advanced for two-stage approval")
    if module.APPROVED_MANIFEST_SHA256 != "UNCONFIGURED":
        fail("source tree no longer defaults to fail-closed approval")

    with tempfile.TemporaryDirectory(
        prefix="wenxintong-app2-attestation-test."
    ) as directory:
        root = Path(directory)
        archive = create_archive(root)
        manifest = root / "app2-release-approval.json"
        module.approval_manifest_path = lambda: manifest

        module.create_candidate_snapshot(archive)
        payload_hash = module.archive_payload_sha256(archive)
        candidate = json.loads(
            (archive / module.CANDIDATE_NAME).read_text(encoding="utf-8")
        )
        if candidate != module.expected_candidate(payload_hash):
            fail("candidate evidence does not bind the candidate payload")
        if (
            candidate["candidate_scope"]
            != "candidate_integrity_evidence_not_release_authorization"
        ):
            fail("candidate evidence overstates release authorization")
        module.verify_candidate_snapshot(archive)
        candidate_path = archive / module.CANDIDATE_NAME
        original_candidate = candidate_path.read_bytes()
        candidate_path.chmod(0o600)
        candidate_path.write_bytes(original_candidate.replace(payload_hash.encode(), b"f" * 64))
        expect_blocked(
            lambda: module.verify_candidate_snapshot(archive),
            "candidate evidence drift unexpectedly passed pre-promotion verification",
        )
        candidate_path.write_bytes(original_candidate)
        candidate_path.chmod(0o400)

        write_manifest(manifest, "0" * 64)
        module.APPROVED_MANIFEST_SHA256 = json_sha256(manifest)
        expect_blocked(
            lambda: module.finalize_snapshot(archive),
            "self-computed candidate passed with a different approved payload hash",
        )
        if (archive / module.ATTESTATION_NAME).exists():
            fail("failed finalization left a misleading final attestation")

        write_manifest(manifest, payload_hash)
        module.APPROVED_MANIFEST_SHA256 = json_sha256(manifest)
        module.finalize_snapshot(archive)
        module.verify(archive)
        evidence = json.loads(
            (archive / module.ATTESTATION_NAME).read_text(encoding="utf-8")
        )
        repository_fields = {
            "approval_manifest_sha256",
            "attestation_script_sha256",
            "archive_verifier_sha256",
            "archive_entrypoint_sha256",
            "package_verifier_sha256",
            "ipa_extractor_sha256",
            "app_payload_evidence_sha256",
            "ipa_verifier_sha256",
            "export_entrypoint_sha256",
            "filesystem_snapshot_sha256",
        }
        expected_keys = {
            "schema_version",
            "attestation_scope",
            "archive_scheme_name",
            "archive_payload_sha256",
            "approved_archive_payload_sha256",
            "candidate_evidence_sha256",
            "app_bundle_relative_path",
            *repository_fields,
        }
        if set(evidence) != expected_keys:
            fail("final attestation field set drifted without a schema update")
        if evidence["approved_archive_payload_sha256"] != payload_hash:
            fail("final attestation does not carry the externally approved hash")

        executable = archive / module.APP_RELATIVE_PATH / "WenxintongApp2"
        mode_before = module.archive_payload_sha256(archive)
        executable.chmod(0o755)
        mode_after = module.archive_payload_sha256(archive)
        if mode_before == mode_after:
            fail("archive payload hash does not bind file modes")
        executable.chmod(0o644)

        app_info = archive / module.APP_RELATIVE_PATH / "Info.plist"
        app_info.write_bytes(app_info.read_bytes() + b"tampered")
        expect_blocked(
            lambda: module.verify(archive),
            "modified archive payload passed final attestation verification",
        )

        special = root / "special.xcarchive"
        special.mkdir()
        os.mkfifo(special / "blocked.fifo")
        expect_blocked(
            lambda: module.archive_payload_sha256(special),
            "FIFO inside an archive was silently ignored",
        )

        linked = root / "linked.xcarchive"
        linked.mkdir()
        (linked / "target").write_bytes(b"target")
        (linked / "blocked-link").symlink_to("target")
        expect_blocked(
            lambda: module.archive_payload_sha256(linked),
            "unapproved archive symbolic link passed",
        )

        manifest_swap = root / "manifest-swap.json"
        approved = "a" * 64
        replaced = "b" * 64
        write_manifest(manifest_swap, approved)
        module.approval_manifest_path = lambda: manifest_swap
        approved_bytes = manifest_swap.read_bytes()
        module.APPROVED_MANIFEST_SHA256 = hashlib.sha256(
            approved_bytes
        ).hexdigest()
        stable_reader = module.stable_regular_file_bytes

        def swap_after_stable_read(path: Path) -> bytes:
            payload = stable_reader(path)
            write_manifest(manifest_swap, replaced)
            return payload

        module.stable_regular_file_bytes = swap_after_stable_read
        loaded, _ = module.load_approval_manifest()
        if loaded.get("approved_archive_payload_sha256") != approved:
            fail("approval manifest parser reopened a swapped pathname")

    print(
        "PASS: APP2 attestation requires a fixed manifest to approve the exact "
        "candidate hash, binds modes, parses the hashed manifest bytes once, "
        "and rejects changed payloads, FIFOs and unapproved links."
    )


if __name__ == "__main__":
    main()
