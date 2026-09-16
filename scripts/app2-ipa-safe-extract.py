#!/usr/bin/env python3
"""Safely extract one APP2 IPA and emit deterministic payload evidence."""

from __future__ import annotations

import hashlib
import json
import os
import shutil
import stat
import sys
import unicodedata
import zipfile
from pathlib import Path, PurePosixPath


MAX_ARCHIVE_BYTES = 1024 * 1024 * 1024
MAX_ENTRIES = 20_000
MAX_FILE_BYTES = 512 * 1024 * 1024
MAX_TOTAL_BYTES = 1536 * 1024 * 1024
MAX_COMPRESSION_RATIO = 200
RATIO_FREE_BYTES = 8 * 1024 * 1024


def fail(message: str) -> None:
    raise SystemExit(f"APP2 IPA extraction blocked: {message}")


def file_sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def normalized_member(info: zipfile.ZipInfo) -> PurePosixPath:
    name = info.filename
    if (
        not name
        or "\x00" in name
        or "\\" in name
        or any(ord(character) < 0x20 or ord(character) == 0x7F for character in name)
    ):
        fail("archive member name is invalid")
    raw = name[:-1] if name.endswith("/") else name
    if not raw or any(part in {"", ".", ".."} for part in raw.split("/")):
        fail("archive member escapes the extraction root")
    path = PurePosixPath(name)
    if path.is_absolute() or not path.parts:
        fail("archive member escapes the extraction root")
    return path


def member_kind(info: zipfile.ZipInfo) -> str:
    mode = (info.external_attr >> 16) & 0xFFFF
    kind = stat.S_IFMT(mode)
    if info.is_dir() or kind == stat.S_IFDIR:
        return "directory"
    if kind in {0, stat.S_IFREG}:
        return "file"
    if kind == stat.S_IFLNK:
        fail("symbolic links are not allowed")
    fail("special archive members are not allowed")


def validate_members(
    archive: zipfile.ZipFile,
) -> tuple[list[tuple[zipfile.ZipInfo, PurePosixPath, str]], PurePosixPath]:
    infos = archive.infolist()
    if not infos or len(infos) > MAX_ENTRIES:
        fail("archive entry count is outside the allowed range")
    validated: list[tuple[zipfile.ZipInfo, PurePosixPath, str]] = []
    path_index: dict[str, tuple[str, str]] = {}
    explicit_paths: set[str] = set()
    app_roots: set[PurePosixPath] = set()
    total_bytes = 0
    for info in infos:
        path = normalized_member(info)
        kind = member_kind(info)
        for index in range(1, len(path.parts) + 1):
            original = PurePosixPath(*path.parts[:index]).as_posix()
            folded = unicodedata.normalize("NFC", original).casefold()
            expected_kind = (
                kind if index == len(path.parts) else "directory"
            )
            existing = path_index.get(folded)
            if existing is not None:
                existing_original, existing_kind = existing
                if existing_original != original:
                    fail("archive contains a Unicode or case-colliding path")
                if existing_kind == "file" or expected_kind == "file":
                    fail("archive contains a file/directory path conflict")
            else:
                path_index[folded] = (original, expected_kind)
        explicit_key = unicodedata.normalize("NFC", path.as_posix()).casefold()
        if explicit_key in explicit_paths:
            fail("archive contains a duplicate path")
        explicit_paths.add(explicit_key)
        if info.flag_bits & 0x1:
            fail("encrypted archive members are not allowed")
        if info.file_size < 0 or info.compress_size < 0 or info.file_size > MAX_FILE_BYTES:
            fail("archive member size is outside the allowed range")
        total_bytes += info.file_size
        if total_bytes > MAX_TOTAL_BYTES:
            fail("archive uncompressed size exceeds the allowed limit")
        if (
            info.file_size > RATIO_FREE_BYTES
            and info.file_size > max(1, info.compress_size) * MAX_COMPRESSION_RATIO
        ):
            fail("archive compression ratio exceeds the allowed limit")
        if len(path.parts) >= 2 and path.parts[0] == "Payload" and path.parts[1].endswith(".app"):
            app_roots.add(PurePosixPath("Payload", path.parts[1]))
        validated.append((info, path, kind))
    if len(app_roots) != 1:
        fail("archive must contain exactly one Payload/*.app")
    app_root = next(iter(app_roots))
    for _, path, _ in validated:
        if path.parts[0] == "Payload" and path != app_root and app_root not in path.parents:
            fail("Payload contains content outside the single APP2 app")
    return validated, app_root


def snapshot_ipa(
    ipa: Path,
    sealed_ipa: Path,
) -> tuple[str, int, os.stat_result]:
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
    descriptor = os.open(ipa, flags)
    try:
        source_state = os.fstat(descriptor)
        if (
            not stat.S_ISREG(source_state.st_mode)
            or source_state.st_size <= 0
            or source_state.st_size > MAX_ARCHIVE_BYTES
        ):
            fail("IPA size or file type is outside the allowed range")
        output_flags = (
            os.O_RDWR
            | os.O_CREAT
            | os.O_EXCL
            | getattr(os, "O_NOFOLLOW", 0)
        )
        output_descriptor = os.open(sealed_ipa, output_flags, 0o400)
        digest = hashlib.sha256()
        copied = 0
        try:
            while True:
                chunk = os.read(descriptor, 1024 * 1024)
                if not chunk:
                    break
                copied += len(chunk)
                if copied > source_state.st_size or copied > MAX_ARCHIVE_BYTES:
                    fail("IPA changed size while it was being snapshotted")
                digest.update(chunk)
                view = memoryview(chunk)
                while view:
                    written = os.write(output_descriptor, view)
                    if written <= 0:
                        fail("sealed IPA snapshot write failed")
                    view = view[written:]
            os.fsync(output_descriptor)
        except BaseException:
            try:
                sealed_ipa.unlink()
            except FileNotFoundError:
                pass
            raise
        if copied != source_state.st_size:
            sealed_ipa.unlink(missing_ok=True)
            fail("IPA size changed while it was being snapshotted")
        final_state = os.fstat(descriptor)
        if (
            final_state.st_size != source_state.st_size
            or final_state.st_mtime_ns != source_state.st_mtime_ns
            or final_state.st_ctime_ns != source_state.st_ctime_ns
        ):
            sealed_ipa.unlink(missing_ok=True)
            fail("IPA content changed while it was being snapshotted")
        sealed_state = os.fstat(output_descriptor)
        os.lseek(output_descriptor, 0, os.SEEK_SET)
        return digest.hexdigest(), output_descriptor, sealed_state
    except BaseException:
        try:
            os.close(output_descriptor)
        except (NameError, OSError):
            pass
        raise
    finally:
        os.close(descriptor)


def extract(ipa: Path, destination: Path, sealed_ipa: Path) -> dict[str, object]:
    if destination.exists() or destination.is_symlink():
        fail("extraction destination must not exist")
    if sealed_ipa.exists() or sealed_ipa.is_symlink():
        fail("sealed IPA destination must not exist")
    if (
        sealed_ipa.parent != destination.parent
        or not sealed_ipa.parent.is_dir()
        or sealed_ipa.parent.is_symlink()
    ):
        fail("sealed IPA and extraction destination must share one existing parent")
    destination_created = False
    sealed_created = False
    sealed_descriptor = -1
    try:
        ipa_digest, sealed_descriptor, sealed_state = snapshot_ipa(ipa, sealed_ipa)
        sealed_created = True
        with os.fdopen(
            os.dup(sealed_descriptor),
            "rb",
            closefd=True,
        ) as sealed_input, zipfile.ZipFile(sealed_input, "r") as archive:
            validated, app_root = validate_members(archive)
            destination.mkdir(mode=0o700, parents=False)
            destination_created = True
            for info, relative, kind in validated:
                target = destination.joinpath(*relative.parts)
                if kind == "directory":
                    target.mkdir(mode=0o700, parents=True, exist_ok=True)
                    continue
                target.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
                written = 0
                output_flags = (
                    os.O_WRONLY
                    | os.O_CREAT
                    | os.O_EXCL
                    | getattr(os, "O_NOFOLLOW", 0)
                )
                output_descriptor = os.open(target, output_flags, 0o600)
                with archive.open(info, "r") as source, os.fdopen(
                    output_descriptor, "wb", closefd=True
                ) as output:
                    while True:
                        chunk = source.read(1024 * 1024)
                        if not chunk:
                            break
                        written += len(chunk)
                        if written > info.file_size or written > MAX_FILE_BYTES:
                            fail("archive member exceeded its declared size")
                        output.write(chunk)
                if written != info.file_size:
                    fail("archive member size does not match its declaration")
                mode = (info.external_attr >> 16) & 0o777
                target.chmod(mode or 0o600)
        try:
            sealed_path_state = os.lstat(sealed_ipa)
        except OSError:
            fail("sealed IPA path changed during extraction")
        sealed_final_state = os.fstat(sealed_descriptor)
        if (
            sealed_state.st_dev != sealed_final_state.st_dev
            or sealed_state.st_ino != sealed_final_state.st_ino
            or sealed_state.st_size != sealed_final_state.st_size
            or sealed_state.st_mtime_ns != sealed_final_state.st_mtime_ns
            or sealed_state.st_ctime_ns != sealed_final_state.st_ctime_ns
            or sealed_final_state.st_dev != sealed_path_state.st_dev
            or sealed_final_state.st_ino != sealed_path_state.st_ino
        ):
            fail("sealed IPA identity changed during extraction")
        os.fchmod(sealed_descriptor, 0o400)
    except (OSError, zipfile.BadZipFile, zipfile.LargeZipFile, RuntimeError):
        if destination_created:
            shutil.rmtree(destination, ignore_errors=True)
        if sealed_created:
            try:
                sealed_ipa.unlink()
            except FileNotFoundError:
                pass
        fail("IPA is unreadable or failed integrity validation")
    except BaseException:
        if destination_created:
            shutil.rmtree(destination, ignore_errors=True)
        if sealed_created:
            try:
                sealed_ipa.unlink()
            except FileNotFoundError:
                pass
        raise
    finally:
        if sealed_descriptor >= 0:
            os.close(sealed_descriptor)
    app_path = destination.joinpath(*app_root.parts)
    if not (app_path / "Info.plist").is_file():
        fail("extracted APP2 app has no Info.plist")
    payload_digest = hashlib.sha256()
    for path in sorted(item for item in app_path.rglob("*") if item.is_file()):
        relative = path.relative_to(app_path).as_posix().encode("utf-8")
        content_hash = bytes.fromhex(file_sha256(path))
        payload_digest.update(len(relative).to_bytes(8, "big"))
        payload_digest.update(relative)
        payload_digest.update(content_hash)
    return {
        "schema_version": 1,
        "ipa_sha256": ipa_digest,
        "app_payload_sha256": payload_digest.hexdigest(),
        "app_bundle_relative_path": app_root.as_posix(),
    }


def main() -> None:
    if len(sys.argv) != 4:
        fail(
            "usage: app2-ipa-safe-extract.py "
            "<source.ipa> <new-extraction-destination> <new-sealed.ipa>"
        )
    ipa = Path(sys.argv[1])
    destination = Path(sys.argv[2])
    sealed_ipa = Path(sys.argv[3])
    if not ipa.is_absolute() or not destination.is_absolute() or not sealed_ipa.is_absolute():
        fail("IPA, extraction destination and sealed IPA must be absolute paths")
    evidence = extract(ipa, destination, sealed_ipa)
    print(json.dumps(evidence, sort_keys=True, separators=(",", ":")))


if __name__ == "__main__":
    main()
