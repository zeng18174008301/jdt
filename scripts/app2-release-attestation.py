#!/usr/bin/env python3
"""Create candidate evidence, then finalize and verify an approved APP2 archive."""

from __future__ import annotations

import hashlib
import json
import os
import plistlib
import stat
import sys
import unicodedata
from pathlib import Path, PurePosixPath

SCRIPT_DIR = Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

from app2_filesystem_snapshot import (  # noqa: E402
    sealed_tree_snapshot,
    stable_file_sha256,
    stable_regular_file_bytes,
)


ATTESTATION_NAME = "APP2_RELEASE_ATTESTATION.json"
CANDIDATE_NAME = "APP2_RELEASE_CANDIDATE.json"
APP_RELATIVE_PATH = "Products/Applications/WenxintongApp2.app"
ARCHIVE_METADATA_APP_PATH = "Applications/WenxintongApp2.app"
ARCHIVE_SCHEME_NAME = "BlueStoneIM-App2"
SCHEMA_VERSION = 5
CANDIDATE_SCHEMA_VERSION = 1
# Freeze this only after the release owner commits the reviewed manifest that
# contains the exact candidate archive payload hash. UNCONFIGURED is deliberate.
APPROVED_MANIFEST_SHA256 = "UNCONFIGURED"
MAX_ARCHIVE_ENTRIES = 100_000
MAX_ARCHIVE_FILE_BYTES = 2 * 1024 * 1024 * 1024
MAX_ARCHIVE_TOTAL_BYTES = 8 * 1024 * 1024 * 1024
APPROVED_SYMLINK_PREFIXES = (
    "Products/Applications/WenxintongApp2.app/Frameworks/",
    "dSYMs/",
)
EVIDENCE_NAMES = {ATTESTATION_NAME, CANDIDATE_NAME}


def fail(message: str) -> None:
    raise SystemExit(f"APP2 release attestation blocked: {message}")


def is_hex_sha256(value: object) -> bool:
    return (
        isinstance(value, str)
        and len(value) == 64
        and all(character in "0123456789abcdef" for character in value)
    )


def file_sha256(path: Path, maximum_bytes: int = MAX_ARCHIVE_FILE_BYTES) -> str:
    try:
        return stable_file_sha256(path, maximum_bytes)
    except SystemExit as error:
        fail(str(error))


def normalized_path_key(relative: str) -> str:
    if (
        not relative
        or "\\" in relative
        or any(ord(character) < 0x20 or ord(character) == 0x7F for character in relative)
    ):
        fail("archive contains an unsafe path")
    return unicodedata.normalize("NFC", relative).casefold()


def normalized_symlink_target(relative: str, target: str) -> str:
    if (
        not target
        or "\x00" in target
        or "\\" in target
        or PurePosixPath(target).is_absolute()
        or any(ord(character) < 0x20 or ord(character) == 0x7F for character in target)
    ):
        fail("archive contains an unsafe symbolic link")
    parts: list[str] = []
    combined = PurePosixPath(relative).parent / PurePosixPath(target)
    for part in combined.parts:
        if part in {"", "."}:
            continue
        if part == "..":
            if not parts:
                fail("archive symbolic link escapes the archive")
            parts.pop()
        else:
            parts.append(part)
    if not parts:
        fail("archive symbolic link has an invalid target")
    return PurePosixPath(*parts).as_posix()


def approved_symlink_target(relative: str, target: str) -> str | None:
    normalized_target = normalized_symlink_target(relative, target)
    for prefix in APPROVED_SYMLINK_PREFIXES:
        if relative.startswith(prefix) and normalized_target.startswith(prefix):
            return normalized_target
    return None


def archive_payload_sha256(
    archive: Path,
    source_modes: dict[str, int] | None = None,
) -> str:
    if not archive.is_dir() or archive.is_symlink():
        fail("archive root must be one regular directory")
    entries: list[tuple[str, bytes, int, bytes]] = []
    seen: set[str] = set()
    entry_kinds: dict[str, bytes] = {}
    symlink_targets: list[tuple[str, str]] = []
    entry_count = 0
    total_bytes = 0
    stack = [archive]
    while stack:
        directory = stack.pop()
        try:
            children = sorted(os.scandir(directory), key=lambda item: item.name)
        except OSError:
            fail("archive tree is unreadable")
        for child in children:
            path = Path(child.path)
            relative = path.relative_to(archive).as_posix()
            key = normalized_path_key(relative)
            if key in seen:
                fail("archive contains a Unicode or case-colliding path")
            seen.add(key)
            entry_count += 1
            if entry_count > MAX_ARCHIVE_ENTRIES:
                fail("archive contains too many entries")
            try:
                state = child.stat(follow_symlinks=False)
            except OSError:
                fail("archive entry cannot be inspected")
            if relative in EVIDENCE_NAMES:
                if not stat.S_ISREG(state.st_mode):
                    fail("archive evidence path has an invalid file type")
                continue
            relative_bytes = relative.encode("utf-8")
            source_mode = (
                source_modes.get(relative)
                if source_modes is not None
                else stat.S_IMODE(state.st_mode)
            )
            if not isinstance(source_mode, int) or source_mode < 0 or source_mode > 0o7777:
                fail("archive source mode evidence is missing or invalid")
            if stat.S_ISDIR(state.st_mode):
                entries.append((relative, b"D", source_mode, b""))
                entry_kinds[key] = b"D"
                stack.append(path)
                continue
            if stat.S_ISLNK(state.st_mode):
                try:
                    target = os.readlink(path)
                except OSError:
                    fail("archive symbolic link is unreadable")
                approved_target = approved_symlink_target(relative, target)
                if approved_target is None:
                    fail("archive contains a symbolic link outside the approved boundary")
                entries.append(
                    (relative, b"L", source_mode, target.encode("utf-8"))
                )
                entry_kinds[key] = b"L"
                symlink_targets.append((relative, approved_target))
                continue
            if not stat.S_ISREG(state.st_mode):
                fail("archive contains a FIFO, socket, device or other special file")
            if state.st_size < 0 or state.st_size > MAX_ARCHIVE_FILE_BYTES:
                fail("archive file size is outside the allowed range")
            total_bytes += state.st_size
            if total_bytes > MAX_ARCHIVE_TOTAL_BYTES:
                fail("archive total size exceeds the allowed range")
            entries.append(
                (
                    relative,
                    b"F",
                    source_mode,
                    bytes.fromhex(file_sha256(path, MAX_ARCHIVE_FILE_BYTES)),
                )
            )
            entry_kinds[key] = b"F"
    for relative, target in symlink_targets:
        if entry_kinds.get(normalized_path_key(target)) not in {b"D", b"F"}:
            fail(f"archive symbolic link target is missing or linked: {relative}")
    if not entries:
        fail("archive payload is empty")
    digest = hashlib.sha256()
    for relative, kind, source_mode, payload in sorted(
        entries,
        key=lambda item: item[0],
    ):
        relative_bytes = relative.encode("utf-8")
        digest.update(kind)
        digest.update(source_mode.to_bytes(4, "big"))
        digest.update(len(relative_bytes).to_bytes(8, "big"))
        digest.update(relative_bytes)
        digest.update(len(payload).to_bytes(8, "big"))
        digest.update(payload)
    return digest.hexdigest()


def approval_manifest_path() -> Path:
    return Path(__file__).resolve().parent / "app2-release-approval.json"


def load_approval_manifest() -> tuple[dict[str, object], str]:
    if not is_hex_sha256(APPROVED_MANIFEST_SHA256):
        fail("repository-trusted approval manifest digest is not frozen")
    manifest_path = approval_manifest_path()
    try:
        manifest_bytes = stable_regular_file_bytes(manifest_path)
    except SystemExit as error:
        fail(str(error))
    actual_digest = hashlib.sha256(manifest_bytes).hexdigest()
    if actual_digest != APPROVED_MANIFEST_SHA256:
        fail("repository-trusted approval manifest digest does not match")
    try:
        manifest = json.loads(manifest_bytes.decode("utf-8"))
    except (UnicodeError, json.JSONDecodeError):
        fail("repository-trusted approval manifest is unreadable")
    if not isinstance(manifest, dict):
        fail("repository-trusted approval manifest is invalid")
    approved_hash = manifest.get("approved_archive_payload_sha256")
    if not is_hex_sha256(approved_hash):
        fail("approval manifest has no exact approved archive payload hash")
    return manifest, actual_digest


def repository_evidence() -> dict[str, str]:
    script_dir = Path(__file__).resolve().parent
    _, manifest_digest = load_approval_manifest()
    verifier = script_dir / "verify-app2-archive.sh"
    archive_entrypoint = script_dir / "archive-app2-release.sh"
    package_verifier = script_dir / "verify-app2-release-package.sh"
    ipa_extractor = script_dir / "app2-ipa-safe-extract.py"
    payload_evidence = script_dir / "app2-app-payload-evidence.py"
    ipa_verifier = script_dir / "verify-app2-ipa.sh"
    export_entrypoint = script_dir / "export-app2-release.sh"
    filesystem_snapshot = script_dir / "app2_filesystem_snapshot.py"
    workflow_files = (
        verifier,
        archive_entrypoint,
        package_verifier,
        ipa_extractor,
        payload_evidence,
        ipa_verifier,
        export_entrypoint,
        filesystem_snapshot,
    )
    if not all(path.is_file() and not path.is_symlink() for path in workflow_files):
        fail("fixed APP2 release workflow is incomplete")
    return {
        "approval_manifest_sha256": manifest_digest,
        "attestation_script_sha256": file_sha256(Path(__file__).resolve()),
        "archive_verifier_sha256": file_sha256(verifier),
        "archive_entrypoint_sha256": file_sha256(archive_entrypoint),
        "package_verifier_sha256": file_sha256(package_verifier),
        "ipa_extractor_sha256": file_sha256(ipa_extractor),
        "app_payload_evidence_sha256": file_sha256(payload_evidence),
        "ipa_verifier_sha256": file_sha256(ipa_verifier),
        "export_entrypoint_sha256": file_sha256(export_entrypoint),
        "filesystem_snapshot_sha256": file_sha256(filesystem_snapshot),
    }


def expected_candidate(payload_hash: str) -> dict[str, object]:
    if not is_hex_sha256(payload_hash):
        fail("candidate archive payload hash is invalid")
    return {
        "schema_version": CANDIDATE_SCHEMA_VERSION,
        "candidate_scope": "candidate_integrity_evidence_not_release_authorization",
        "archive_scheme_name": ARCHIVE_SCHEME_NAME,
        "archive_payload_sha256": payload_hash,
        "app_bundle_relative_path": APP_RELATIVE_PATH,
    }


def load_json_object(path: Path, label: str) -> tuple[dict[str, object], str]:
    try:
        payload = stable_regular_file_bytes(path)
        value = json.loads(payload.decode("utf-8"))
    except (SystemExit, UnicodeError, json.JSONDecodeError):
        fail(f"{label} is unreadable")
    if not isinstance(value, dict):
        fail(f"{label} is invalid")
    return value, hashlib.sha256(payload).hexdigest()


def validate_candidate(archive: Path, payload_hash: str) -> str:
    candidate_path = archive / CANDIDATE_NAME
    candidate, candidate_digest = load_json_object(
        candidate_path,
        "candidate archive evidence",
    )
    if candidate != expected_candidate(payload_hash):
        fail("candidate evidence does not match the current archive payload")
    return candidate_digest


def expected_attestation(
    archive: Path,
    source_modes: dict[str, int] | None = None,
) -> dict[str, object]:
    payload_hash = archive_payload_sha256(archive, source_modes)
    candidate_hash = validate_candidate(archive, payload_hash)
    manifest, _ = load_approval_manifest()
    approved_hash = manifest["approved_archive_payload_sha256"]
    if approved_hash != payload_hash:
        fail("approval manifest does not approve this exact archive payload")
    return {
        "schema_version": SCHEMA_VERSION,
        "attestation_scope": "approved_archive_integrity_gate_not_distribution_authorization",
        "archive_scheme_name": ARCHIVE_SCHEME_NAME,
        "archive_payload_sha256": payload_hash,
        "approved_archive_payload_sha256": approved_hash,
        "candidate_evidence_sha256": candidate_hash,
        "app_bundle_relative_path": APP_RELATIVE_PATH,
        **repository_evidence(),
    }


def validate_archive(archive: Path) -> None:
    if (
        not archive.is_dir()
        or archive.is_symlink()
        or not (archive / APP_RELATIVE_PATH / "Info.plist").is_file()
    ):
        fail("pass the final APP2 xcarchive directory")
    try:
        with (archive / "Info.plist").open("rb") as handle:
            metadata = plistlib.load(handle)
    except (OSError, plistlib.InvalidFileException):
        fail("xcarchive metadata is missing or unreadable")
    application = metadata.get("ApplicationProperties") if isinstance(metadata, dict) else None
    if (
        metadata.get("SchemeName") != ARCHIVE_SCHEME_NAME
        or not isinstance(application, dict)
        or application.get("ApplicationPath") != ARCHIVE_METADATA_APP_PATH
    ):
        fail("archive was not produced for the fixed APP2 scheme and target product")


def write_new_json(destination: Path, value: dict[str, object]) -> None:
    payload = json.dumps(
        value,
        ensure_ascii=True,
        sort_keys=True,
        separators=(",", ":"),
    ).encode("utf-8") + b"\n"
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0)
    try:
        descriptor = os.open(destination, flags, 0o400)
    except OSError:
        fail("refusing to overwrite existing release evidence")
    try:
        with os.fdopen(descriptor, "wb", closefd=True) as handle:
            handle.write(payload)
            handle.flush()
            os.fsync(handle.fileno())
    except BaseException:
        try:
            destination.unlink()
        except FileNotFoundError:
            pass
        raise


def create_candidate_snapshot(archive: Path) -> None:
    validate_archive(archive)
    if (archive / ATTESTATION_NAME).exists() or (archive / CANDIDATE_NAME).exists():
        fail("candidate or final attestation already exists")
    payload_hash = archive_payload_sha256(archive)
    write_new_json(
        archive / CANDIDATE_NAME,
        expected_candidate(payload_hash),
    )
    if validate_candidate(archive, archive_payload_sha256(archive)) != file_sha256(
        archive / CANDIDATE_NAME
    ):
        fail("candidate evidence changed after creation")


def verify_candidate_snapshot(archive: Path) -> None:
    validate_archive(archive)
    if (archive / ATTESTATION_NAME).exists():
        fail("candidate snapshot unexpectedly contains a final attestation")
    payload_hash = archive_payload_sha256(archive)
    validate_candidate(archive, payload_hash)


def finalize_snapshot(archive: Path) -> None:
    validate_archive(archive)
    if (archive / ATTESTATION_NAME).exists():
        fail("final attestation already exists")
    write_new_json(archive / ATTESTATION_NAME, expected_attestation(archive))
    verify_snapshot(archive)


def verify(archive: Path) -> None:
    with sealed_tree_snapshot(archive, "archive") as snapshot:
        verify_snapshot(snapshot.root, snapshot.source_modes)


def verify_snapshot(
    archive: Path,
    source_modes: dict[str, int] | None = None,
) -> None:
    validate_archive(archive)
    actual, _ = load_json_object(
        archive / ATTESTATION_NAME,
        "final archive attestation",
    )
    expected = expected_attestation(archive, source_modes)
    if actual != expected:
        fail("release attestation does not match the approved archive payload")


def emit_approval_manifest() -> None:
    manifest, _ = load_approval_manifest()
    sys.stdout.write(
        json.dumps(
            manifest,
            ensure_ascii=True,
            sort_keys=True,
            separators=(",", ":"),
        )
        + "\n"
    )


def main() -> None:
    if len(sys.argv) == 2 and sys.argv[1] == "manifest":
        emit_approval_manifest()
        return
    if len(sys.argv) != 3 or sys.argv[1] not in {
        "candidate-snapshot",
        "verify-candidate-snapshot",
        "finalize-snapshot",
        "verify",
        "verify-snapshot",
    }:
        fail(
            "usage: app2-release-attestation.py "
            "candidate-snapshot|verify-candidate-snapshot|"
            "finalize-snapshot|verify|verify-snapshot "
            "<archive.xcarchive> | manifest"
        )
    archive = Path(sys.argv[2]).resolve()
    if sys.argv[1] == "candidate-snapshot":
        create_candidate_snapshot(archive)
    elif sys.argv[1] == "verify-candidate-snapshot":
        verify_candidate_snapshot(archive)
    elif sys.argv[1] == "finalize-snapshot":
        finalize_snapshot(archive)
    elif sys.argv[1] == "verify-snapshot":
        verify_snapshot(archive)
    else:
        verify(archive)


if __name__ == "__main__":
    main()
