#!/usr/bin/env python3
"""Verify the final signed APP1 archive against its frozen public identity."""

from __future__ import annotations

import datetime
import hashlib
import os
import plistlib
import subprocess
import sys
import tempfile
from pathlib import Path


EXPECTED_BUNDLE_ID = "com.wendatongqiye.app"
EXPECTED_TEAM_ID = "A3PN7W63G3"
EXPECTED_APS_ENVIRONMENT = "production"
EXPECTED_ORDINARY_TOPIC = EXPECTED_BUNDLE_ID
EXPECTED_VOIP_TOPIC = f"{EXPECTED_BUNDLE_ID}.voip"
FORMAL_MODE = "formal"
INTERNAL_VALIDATION_MODE = "internal-validation"
DIAGNOSTICS_BINARY_MARKER = b"WXT_ACCESS_DIAGNOSTICS_OVERLAY_BINARY_MARKER_V1"


class ArchiveVerificationError(Exception):
    """A public, non-secret failure suitable for Xcode archive output."""


def fail(message: str) -> None:
    raise ArchiveVerificationError(message)


def run_tool(arguments: list[str], failure_message: str) -> bytes:
    try:
        result = subprocess.run(arguments, capture_output=True, check=False)
    except OSError:
        fail(failure_message)
    if result.returncode != 0:
        fail(failure_message)
    return result.stdout


def load_plist_bytes(value: bytes) -> dict[str, object]:
    decoded = plistlib.loads(value)
    if not isinstance(decoded, dict):
        raise ValueError("plist")
    return decoded


def load_plist(path: Path) -> dict[str, object]:
    with path.open("rb") as handle:
        decoded = plistlib.load(handle)
    if not isinstance(decoded, dict):
        raise ValueError("plist")
    return decoded


def required_text(value: object) -> str:
    if not isinstance(value, str) or not value or value != value.strip():
        raise ValueError("text")
    return value


def verify_identity(
    info: dict[str, object],
    entitlements: dict[str, object],
    profile: dict[str, object],
    leaf_certificate: bytes,
) -> tuple[str, str]:
    if required_text(info.get("CFBundleIdentifier")) != EXPECTED_BUNDLE_ID:
        raise ValueError("bundle")
    if info.get("WXTAPNsEnvironment") != EXPECTED_APS_ENVIRONMENT:
        raise ValueError("Info APNs environment")
    if EXPECTED_ORDINARY_TOPIC != EXPECTED_BUNDLE_ID:
        raise ValueError("ordinary topic")
    if EXPECTED_VOIP_TOPIC != f"{EXPECTED_BUNDLE_ID}.voip":
        raise ValueError("VoIP topic")

    application_identifier = f"{EXPECTED_TEAM_ID}.{EXPECTED_BUNDLE_ID}"
    if entitlements.get("application-identifier") != application_identifier:
        raise ValueError("application identifier")
    if entitlements.get("com.apple.developer.team-identifier") != EXPECTED_TEAM_ID:
        raise ValueError("team")
    if entitlements.get("aps-environment") != EXPECTED_APS_ENVIRONMENT:
        raise ValueError("aps")
    if entitlements.get("get-task-allow") not in {None, False}:
        raise ValueError("debug entitlement")

    required_text(profile.get("Name"))
    profile_uuid = required_text(profile.get("UUID"))
    team_identifiers = profile.get("TeamIdentifier")
    if not isinstance(team_identifiers, list) or team_identifiers != [EXPECTED_TEAM_ID]:
        raise ValueError("profile team")
    profile_entitlements = profile.get("Entitlements")
    if not isinstance(profile_entitlements, dict):
        raise ValueError("profile entitlements")
    if profile_entitlements.get("application-identifier") != application_identifier:
        raise ValueError("profile application identifier")
    if profile_entitlements.get("com.apple.developer.team-identifier") != EXPECTED_TEAM_ID:
        raise ValueError("profile team entitlement")
    if profile_entitlements.get("aps-environment") != EXPECTED_APS_ENVIRONMENT:
        raise ValueError("profile aps")
    if profile_entitlements.get("get-task-allow") not in {None, False}:
        raise ValueError("profile debug entitlement")

    expiration = profile.get("ExpirationDate")
    if not isinstance(expiration, datetime.datetime):
        raise ValueError("profile expiration")
    if expiration.tzinfo is None:
        expiration = expiration.replace(tzinfo=datetime.timezone.utc)
    if expiration <= datetime.datetime.now(datetime.timezone.utc):
        raise ValueError("expired profile")

    leaf_hash = hashlib.sha256(leaf_certificate).hexdigest()
    certificates = profile.get("DeveloperCertificates")
    certificate_hashes = {
        hashlib.sha256(bytes(value)).hexdigest()
        for value in certificates
        if isinstance(value, (bytes, bytearray))
    } if isinstance(certificates, list) else set()
    if leaf_hash not in certificate_hashes:
        raise ValueError("signing certificate")
    return profile_uuid, leaf_hash


def verify_diagnostics_boundary(
    info: dict[str, object], executable: Path, mode: str
) -> None:
    metadata = info.get("WXTAccessDiagnosticsOverlayCompiled")
    marker_is_present = DIAGNOSTICS_BINARY_MARKER in executable.read_bytes()
    if metadata != "YES":
        fail(f"{mode} archive is missing diagnostics capability metadata")
    if not marker_is_present:
        fail(f"{mode} archive is missing the diagnostics capability marker")
    if mode == INTERNAL_VALIDATION_MODE:
        if info.get("WXTFormalBuild") not in {False, "NO", "0"}:
            fail("internal-validation archive is incorrectly labeled as formal")


def verify_archive(app_path: Path, mode: str = FORMAL_MODE) -> None:
    if not app_path.is_dir() or not (app_path / "Info.plist").is_file():
        fail("pass the final archived APP1 .app directory")

    info = load_plist(app_path / "Info.plist")
    executable_name = info.get("CFBundleExecutable")
    if (
        not isinstance(executable_name, str)
        or not executable_name
        or executable_name in {".", ".."}
        or "/" in executable_name
        or "\\" in executable_name
    ):
        fail("final app executable identity is invalid")
    executable = app_path / executable_name
    if not executable.is_file() or executable.is_symlink():
        fail("final app executable is missing")
    verify_diagnostics_boundary(info, executable, mode)

    codesign_tool = Path(os.environ.get("APP1_VERIFY_CODESIGN_TOOL", "/usr/bin/codesign"))
    security_tool = Path(os.environ.get("APP1_VERIFY_SECURITY_TOOL", "/usr/bin/security"))
    if not codesign_tool.is_file() or not os.access(codesign_tool, os.X_OK):
        fail("codesign verifier is unavailable")
    if not security_tool.is_file() or not os.access(security_tool, os.X_OK):
        fail("provisioning profile decoder is unavailable")

    run_tool(
        [str(codesign_tool), "--verify", "--deep", "--strict", str(app_path)],
        "final app code signature is invalid",
    )
    embedded_profile = app_path / "embedded.mobileprovision"
    if not embedded_profile.is_file():
        fail("final archive is missing embedded.mobileprovision")

    entitlements_bytes = run_tool(
        [str(codesign_tool), "-d", "--entitlements", ":-", str(app_path)],
        "cannot read final signed entitlements",
    )
    profile_bytes = run_tool(
        [str(security_tool), "cms", "-D", "-i", str(embedded_profile)],
        "cannot decode final provisioning profile",
    )
    with tempfile.TemporaryDirectory(prefix="app1-archive-verify-") as temporary:
        certificate_prefix = Path(temporary) / "signing-cert"
        run_tool(
            [
                str(codesign_tool),
                "-d",
                "--extract-certificates",
                str(certificate_prefix),
                str(app_path),
            ],
            "cannot extract the final signing certificate",
        )
        leaf_certificate_path = Path(f"{certificate_prefix}0")
        if not leaf_certificate_path.is_file():
            fail("final signature has no leaf signing certificate")
        leaf_certificate = leaf_certificate_path.read_bytes()

    try:
        profile_uuid, leaf_hash = verify_identity(
            info,
            load_plist_bytes(entitlements_bytes),
            load_plist_bytes(profile_bytes),
            leaf_certificate,
        )
    except (OSError, ValueError, plistlib.InvalidFileException):
        fail("final archive Bundle/Team/Profile/topic identity mismatch")

    verification_label = (
        "APP1 internal-validation archive verified diagnostics=required"
        if mode == INTERNAL_VALIDATION_MODE
        else "APP1 final archive verified diagnostics=required"
    )
    print(
        f"PASS: {verification_label} "
        f"bundle={EXPECTED_BUNDLE_ID} team={EXPECTED_TEAM_ID} "
        f"profile_uuid={profile_uuid} aps={EXPECTED_APS_ENVIRONMENT} "
        f"ordinary_topic={EXPECTED_ORDINARY_TOPIC} voip_topic={EXPECTED_VOIP_TOPIC} "
        f"certificate_sha256={leaf_hash}"
    )


def parse_arguments(arguments: list[str]) -> tuple[str, Path]:
    if len(arguments) == 2:
        return FORMAL_MODE, Path(arguments[1])
    if (
        len(arguments) == 4
        and arguments[1] == "--mode"
        and arguments[2] in {FORMAL_MODE, INTERNAL_VALIDATION_MODE}
    ):
        return arguments[2], Path(arguments[3])
    fail(
        "usage: verify_app1_archive.py "
        "[--mode formal|internal-validation] <archived-app-directory>"
    )


def main(arguments: list[str]) -> int:
    try:
        mode, app_path = parse_arguments(arguments)
        verify_archive(app_path, mode)
    except ArchiveVerificationError as error:
        print(f"APP1 archive blocked: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
