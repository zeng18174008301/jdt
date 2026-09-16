#!/usr/bin/env python3
"""Compare one sealed APP2 archive app with its exported IPA app."""

from __future__ import annotations

import hashlib
import json
import os
import plistlib
import stat
import subprocess
import sys
import tempfile
import unicodedata
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

from app2_filesystem_snapshot import sealed_tree_snapshot  # noqa: E402


MAX_ENTRIES = 50_000
MAX_FILE_BYTES = 512 * 1024 * 1024
MAX_TOTAL_BYTES = 1536 * 1024 * 1024
SIGNED_BUNDLE_SUFFIXES = (".app", ".appex", ".framework", ".xpc")


def fail(message: str) -> None:
    raise SystemExit(f"APP2 payload evidence blocked: {message}")


def sha256_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def file_sha256(path: Path) -> str:
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
    try:
        descriptor = os.open(path, flags)
    except OSError:
        fail("app file is unreadable or linked")
    digest = hashlib.sha256()
    copied = 0
    try:
        before = os.fstat(descriptor)
        if not stat.S_ISREG(before.st_mode) or before.st_size > MAX_FILE_BYTES:
            fail("app file type or size is outside the allowed range")
        with os.fdopen(descriptor, "rb", closefd=False) as handle:
            for chunk in iter(lambda: handle.read(1024 * 1024), b""):
                copied += len(chunk)
                if copied > before.st_size or copied > MAX_FILE_BYTES:
                    fail("app file changed while it was being hashed")
                digest.update(chunk)
        after = os.fstat(descriptor)
        try:
            current = os.lstat(path)
        except OSError:
            fail("app file path changed while it was being hashed")
        if (
            copied != before.st_size
            or before.st_dev != after.st_dev
            or before.st_ino != after.st_ino
            or before.st_size != after.st_size
            or before.st_mtime_ns != after.st_mtime_ns
            or before.st_ctime_ns != after.st_ctime_ns
            or not stat.S_ISREG(current.st_mode)
            or current.st_dev != after.st_dev
            or current.st_ino != after.st_ino
        ):
            fail("app file changed while it was being hashed")
    finally:
        os.close(descriptor)
    return digest.hexdigest()


def canonical_plist_sha256(value: object) -> str:
    return sha256_bytes(
        plistlib.dumps(value, fmt=plistlib.FMT_BINARY, sort_keys=True)
    )


def load_plist(path: Path) -> dict[str, object]:
    try:
        with path.open("rb") as handle:
            value = plistlib.load(handle)
    except (OSError, plistlib.InvalidFileException):
        fail(f"plist is unreadable: {path.name}")
    if not isinstance(value, dict):
        fail(f"plist root is invalid: {path.name}")
    return value


def normalized_key(relative: str) -> str:
    return unicodedata.normalize("NFC", relative).casefold()


def scan_tree(root: Path) -> dict[str, object]:
    if not root.is_dir() or root.is_symlink():
        fail("app root must be one regular directory")
    root_state = os.lstat(root)
    files: dict[str, dict[str, object]] = {}
    directories: dict[str, int] = {}
    seen: set[str] = set()
    bundle_paths: set[str] = {"."}
    total_bytes = 0
    entry_count = 0
    stack = [root]
    while stack:
        directory = stack.pop()
        try:
            children = sorted(os.scandir(directory), key=lambda item: item.name)
        except OSError:
            fail("app tree is unreadable")
        for child in children:
            path = Path(child.path)
            relative = path.relative_to(root).as_posix()
            key = normalized_key(relative)
            if key in seen:
                fail("app tree contains a Unicode or case-colliding path")
            seen.add(key)
            entry_count += 1
            if entry_count > MAX_ENTRIES:
                fail("app tree contains too many entries")
            state = child.stat(follow_symlinks=False)
            if stat.S_ISLNK(state.st_mode):
                fail("app tree contains a symbolic link")
            if stat.S_ISDIR(state.st_mode):
                directories[relative] = stat.S_IMODE(state.st_mode)
                if child.name.lower().endswith(SIGNED_BUNDLE_SUFFIXES):
                    bundle_paths.add(relative)
                stack.append(path)
                continue
            if not stat.S_ISREG(state.st_mode):
                fail("app tree contains a special file")
            if state.st_size < 0 or state.st_size > MAX_FILE_BYTES:
                fail("app file size is outside the allowed range")
            total_bytes += state.st_size
            if total_bytes > MAX_TOTAL_BYTES:
                fail("app tree size exceeds the allowed range")
            files[relative] = {
                "type": "regular",
                "sha256": file_sha256(path),
                "size": state.st_size,
                "mode": stat.S_IMODE(state.st_mode),
            }
    return {
        "files": files,
        "root_mode": stat.S_IMODE(root_state.st_mode),
        "directories": directories,
        "bundle_paths": sorted(bundle_paths),
    }


def bundle_info_path(bundle: Path) -> Path | None:
    candidates = (bundle / "Info.plist", bundle / "Resources" / "Info.plist")
    return next((candidate for candidate in candidates if candidate.is_file()), None)


def bundle_metadata(root: Path, relative: str) -> dict[str, object]:
    bundle = root if relative == "." else root / relative
    info_path = bundle_info_path(bundle)
    info: dict[str, object] = {}
    if info_path is not None:
        info = load_plist(info_path)
    elif relative == "." or bundle.suffix.lower() in {".app", ".appex"}:
        fail("signed application bundle has no Info.plist")
    executable_name = info.get("CFBundleExecutable")
    if not isinstance(executable_name, str) or not executable_name:
        if bundle.suffix.lower() == ".framework":
            executable_name = bundle.stem
        else:
            fail("signed bundle has no CFBundleExecutable")
    if (
        executable_name in {".", ".."}
        or "/" in executable_name
        or "\\" in executable_name
        or any(ord(character) < 0x20 or ord(character) == 0x7F for character in executable_name)
    ):
        fail("signed bundle executable name is unsafe")
    executable = bundle / executable_name
    if not executable.is_file() or executable.is_symlink():
        fail("signed bundle executable is missing")
    executable_relative = executable.relative_to(root).as_posix()
    bundle_id = info.get("CFBundleIdentifier")
    if bundle_id is not None and (not isinstance(bundle_id, str) or not bundle_id):
        fail("signed bundle identifier is invalid")
    return {
        "bundle": bundle,
        "bundle_id": bundle_id,
        "executable_relative_path": executable_relative,
        "executable_sha256": file_sha256(executable),
    }


def run_checked(arguments: list[str]) -> bytes:
    result = subprocess.run(arguments, capture_output=True, check=False)
    if result.returncode != 0:
        fail("signed bundle verification command failed")
    return result.stdout


def unsigned_executable_sha256(executable: Path) -> str:
    with tempfile.TemporaryDirectory(
        prefix="wenxintong-app2-unsigned-executable."
    ) as directory:
        canonical = Path(directory) / "executable"
        source_flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
        destination_flags = (
            os.O_WRONLY
            | os.O_CREAT
            | os.O_EXCL
            | getattr(os, "O_NOFOLLOW", 0)
        )
        try:
            source_descriptor = os.open(executable, source_flags)
        except OSError:
            fail("signed bundle executable cannot be copied for normalization")
        try:
            source_state = os.fstat(source_descriptor)
            if (
                not stat.S_ISREG(source_state.st_mode)
                or source_state.st_size > MAX_FILE_BYTES
            ):
                fail("signed bundle executable type or size is invalid")
            destination_descriptor = os.open(
                canonical,
                destination_flags,
                0o700,
            )
            copied = 0
            try:
                with os.fdopen(
                    source_descriptor, "rb", closefd=False
                ) as source, os.fdopen(
                    destination_descriptor, "wb", closefd=True
                ) as destination:
                    for chunk in iter(lambda: source.read(1024 * 1024), b""):
                        copied += len(chunk)
                        if copied > source_state.st_size:
                            fail("signed bundle executable changed during normalization")
                        destination.write(chunk)
                    destination.flush()
                    os.fsync(destination.fileno())
            except BaseException:
                try:
                    canonical.unlink()
                except FileNotFoundError:
                    pass
                raise
            after = os.fstat(source_descriptor)
            try:
                current = os.lstat(executable)
            except OSError:
                fail("signed bundle executable path changed during normalization")
            if (
                copied != source_state.st_size
                or source_state.st_dev != after.st_dev
                or source_state.st_ino != after.st_ino
                or source_state.st_size != after.st_size
                or source_state.st_mtime_ns != after.st_mtime_ns
                or source_state.st_ctime_ns != after.st_ctime_ns
                or not stat.S_ISREG(current.st_mode)
                or current.st_dev != after.st_dev
                or current.st_ino != after.st_ino
            ):
                fail("signed bundle executable changed during normalization")
        finally:
            os.close(source_descriptor)
        run_checked(["codesign", "--remove-signature", str(canonical)])
        if not canonical.is_file() or canonical.is_symlink():
            fail("normalized signed bundle executable is invalid")
        return file_sha256(canonical)


def signed_bundle_evidence(root: Path, relative: str) -> dict[str, object]:
    metadata = bundle_metadata(root, relative)
    bundle = metadata.pop("bundle")
    assert isinstance(bundle, Path)
    executable_relative = metadata["executable_relative_path"]
    assert isinstance(executable_relative, str)
    executable = root / executable_relative
    run_checked(["codesign", "--verify", "--strict", str(bundle)])
    entitlements_raw = run_checked(
        ["codesign", "-d", "--entitlements", ":-", str(bundle)]
    )
    entitlements: dict[str, object]
    if entitlements_raw.strip():
        try:
            loaded_entitlements = plistlib.loads(entitlements_raw)
        except plistlib.InvalidFileException:
            fail("signed bundle entitlements are unreadable")
        if not isinstance(loaded_entitlements, dict):
            fail("signed bundle entitlements are invalid")
        entitlements = loaded_entitlements
    else:
        entitlements = {}
    with tempfile.TemporaryDirectory(prefix="wenxintong-app2-cert.") as directory:
        prefix = Path(directory) / "signing-cert"
        run_checked(
            ["codesign", "-d", "--extract-certificates", str(prefix), str(bundle)]
        )
        certificate = Path(f"{prefix}0")
        if not certificate.is_file():
            fail("signed bundle has no leaf certificate")
        certificate_sha256 = file_sha256(certificate)

    profile_path = bundle / "embedded.mobileprovision"
    requires_profile = relative == "." or bundle.suffix.lower() in {".app", ".appex"}
    profile_evidence: dict[str, object] | None = None
    if profile_path.is_file() and not profile_path.is_symlink():
        profile_raw = run_checked(["security", "cms", "-D", "-i", str(profile_path)])
        try:
            profile = plistlib.loads(profile_raw)
        except plistlib.InvalidFileException:
            fail("embedded provisioning profile is unreadable")
        if not isinstance(profile, dict):
            fail("embedded provisioning profile is invalid")
        profile_entitlements = profile.get("Entitlements")
        if not isinstance(profile_entitlements, dict):
            fail("embedded provisioning profile has no entitlements")
        profile_evidence = {
            "sha256": file_sha256(profile_path),
            "uuid": profile.get("UUID"),
            "team_identifier": profile.get("TeamIdentifier"),
            "entitlements_sha256": canonical_plist_sha256(profile_entitlements),
        }
    elif requires_profile:
        fail("signed application bundle has no embedded provisioning profile")

    return {
        "relative_path": relative,
        **metadata,
        "unsigned_executable_sha256": unsigned_executable_sha256(executable),
        "entitlements_sha256": canonical_plist_sha256(entitlements),
        "application_identifier": entitlements.get("application-identifier"),
        "team_identifier": entitlements.get("com.apple.developer.team-identifier"),
        "certificate_sha256": certificate_sha256,
        "profile": profile_evidence,
    }


def tree_digest(
    root_mode: int,
    directories: dict[str, int],
    files: dict[str, dict[str, object]],
    included: set[str],
) -> str:
    digest = hashlib.sha256()
    digest.update(b"R")
    digest.update(root_mode.to_bytes(4, "big"))
    for relative, mode in sorted(directories.items()):
        relative_bytes = relative.encode("utf-8")
        digest.update(b"D")
        digest.update(len(relative_bytes).to_bytes(8, "big"))
        digest.update(relative_bytes)
        digest.update(mode.to_bytes(4, "big"))
    for relative in sorted(included):
        entry = files[relative]
        relative_bytes = relative.encode("utf-8")
        digest.update(b"F")
        digest.update(len(relative_bytes).to_bytes(8, "big"))
        digest.update(relative_bytes)
        digest.update(int(entry["mode"]).to_bytes(4, "big"))
        digest.update(int(entry["size"]).to_bytes(8, "big"))
        digest.update(bytes.fromhex(str(entry["sha256"])))
    return digest.hexdigest()


def mutable_paths(
    bundle_evidence: list[dict[str, object]],
    files: dict[str, dict[str, object]],
    directories: set[str],
) -> set[str]:
    mutable: set[str] = set()
    expected_signature_directories: set[str] = set()
    for bundle in bundle_evidence:
        relative = str(bundle["relative_path"])
        prefix = "" if relative == "." else relative + "/"
        mutable.add(str(bundle["executable_relative_path"]))
        profile = prefix + "embedded.mobileprovision"
        if profile in files:
            mutable.add(profile)
        signature_prefix = prefix + "_CodeSignature/"
        signature_directory = prefix + "_CodeSignature"
        expected_signature_directories.add(signature_directory)
        signature_directories = {
            path
            for path in directories
            if path == signature_directory or path.startswith(signature_prefix)
        }
        if signature_directories != {signature_directory}:
            fail("signed bundle has unexpected or missing _CodeSignature directories")
        signature_files = {
            path for path in files if path.startswith(signature_prefix)
        }
        expected_signature = signature_prefix + "CodeResources"
        if signature_files != {expected_signature}:
            fail("signed bundle has unexpected or missing _CodeSignature content")
        mutable.add(expected_signature)
    actual_signature_directories = {
        path for path in directories if path.rsplit("/", 1)[-1] == "_CodeSignature"
    }
    if actual_signature_directories != expected_signature_directories:
        fail("app contains an unowned or missing _CodeSignature directory")
    return mutable


def compare_snapshots(archive_root: Path, export_root: Path) -> dict[str, object]:
    archive_tree = scan_tree(archive_root)
    export_tree = scan_tree(export_root)
    if archive_tree["bundle_paths"] != export_tree["bundle_paths"]:
        fail("archive and IPA signed bundle sets differ")
    archive_files = archive_tree["files"]
    export_files = export_tree["files"]
    assert isinstance(archive_files, dict) and isinstance(export_files, dict)
    if archive_tree["root_mode"] != export_tree["root_mode"]:
        fail("archive and IPA app root modes differ")
    archive_directories = dict(archive_tree["directories"])
    export_directories = dict(export_tree["directories"])
    if archive_directories != export_directories:
        fail("archive and IPA recursive directory paths or modes differ")
    if set(archive_files) != set(export_files):
        fail("archive and IPA recursive file sets differ")
    for relative in archive_files:
        if (
            archive_files[relative]["type"] != export_files[relative]["type"]
            or archive_files[relative]["mode"] != export_files[relative]["mode"]
        ):
            fail("archive and IPA recursive file types or modes differ")

    bundle_paths = archive_tree["bundle_paths"]
    assert isinstance(bundle_paths, list)
    archive_bundles = [
        signed_bundle_evidence(archive_root, relative) for relative in bundle_paths
    ]
    export_bundles = [
        signed_bundle_evidence(export_root, relative) for relative in bundle_paths
    ]
    archive_mutable = mutable_paths(
        archive_bundles,
        archive_files,
        set(archive_directories),
    )
    export_mutable = mutable_paths(
        export_bundles,
        export_files,
        set(export_directories),
    )
    if archive_mutable != export_mutable:
        fail("archive and IPA signing-mutable file sets differ")
    stable = set(archive_files) - archive_mutable
    for relative in stable:
        if archive_files[relative] != export_files[relative]:
            fail("archive and IPA stable recursive content differs")

    compared_bundles: list[dict[str, object]] = []
    for archive_bundle, export_bundle in zip(archive_bundles, export_bundles):
        for key in (
            "relative_path",
            "bundle_id",
            "executable_relative_path",
            "unsigned_executable_sha256",
            "entitlements_sha256",
            "application_identifier",
            "team_identifier",
            "certificate_sha256",
            "profile",
        ):
            if archive_bundle.get(key) != export_bundle.get(key):
                fail(f"archive and IPA nested signing evidence differs: {key}")
        compared_bundles.append(
            {
                **export_bundle,
                "archive_executable_sha256": archive_bundle["executable_sha256"],
                "export_executable_sha256": export_bundle["executable_sha256"],
                "unsigned_executable_sha256": archive_bundle[
                    "unsigned_executable_sha256"
                ],
            }
        )
    all_paths = set(archive_files)
    return {
        "schema_version": 1,
        "root_mode": int(archive_tree["root_mode"]),
        "directory_modes": dict(sorted(archive_directories.items())),
        "stable_payload_sha256": tree_digest(
            int(archive_tree["root_mode"]),
            archive_directories,
            archive_files,
            stable,
        ),
        "archive_tree_sha256": tree_digest(
            int(archive_tree["root_mode"]),
            archive_directories,
            archive_files,
            all_paths,
        ),
        "export_tree_sha256": tree_digest(
            int(export_tree["root_mode"]),
            export_directories,
            export_files,
            all_paths,
        ),
        "signing_mutable_paths": sorted(archive_mutable),
        "signed_bundles": compared_bundles,
    }


def compare(archive_root: Path, export_root: Path) -> dict[str, object]:
    with sealed_tree_snapshot(archive_root, "app") as archived:
        with sealed_tree_snapshot(export_root, "app") as exported:
            return compare_snapshots(archived.root, exported.root)


def main() -> None:
    if len(sys.argv) != 3:
        fail("usage: app2-app-payload-evidence.py <archive.app> <exported.app>")
    archive_root = Path(sys.argv[1])
    export_root = Path(sys.argv[2])
    if not archive_root.is_absolute() or not export_root.is_absolute():
        fail("archive and exported app paths must be absolute")
    print(
        json.dumps(
            compare(archive_root, export_root),
            sort_keys=True,
            separators=(",", ":"),
        )
    )


if __name__ == "__main__":
    main()
