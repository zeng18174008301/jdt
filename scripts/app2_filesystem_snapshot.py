#!/usr/bin/env python3
"""Create and consume one stable, private APP2 filesystem snapshot."""

from __future__ import annotations

import contextlib
import ctypes
import errno
import hashlib
import os
import secrets
import stat
import subprocess
import sys
import tempfile
import unicodedata
from dataclasses import dataclass
from pathlib import Path
from typing import Callable, Iterator


ARCHIVE_MAX_ENTRIES = 100_000
ARCHIVE_MAX_FILE_BYTES = 2 * 1024 * 1024 * 1024
ARCHIVE_MAX_TOTAL_BYTES = 8 * 1024 * 1024 * 1024
APP_MAX_ENTRIES = 50_000
APP_MAX_FILE_BYTES = 512 * 1024 * 1024
APP_MAX_TOTAL_BYTES = 1536 * 1024 * 1024
READ_MAX_BYTES = 4 * 1024 * 1024
COPY_CHUNK_BYTES = 1024 * 1024
APPROVED_ARCHIVE_SYMLINK_PREFIXES = (
    "Products/Applications/WenxintongApp2.app/Frameworks/",
    "dSYMs/",
)


def fail(message: str) -> None:
    raise SystemExit(f"APP2 filesystem snapshot blocked: {message}")


@dataclass(frozen=True)
class SnapshotLimits:
    max_entries: int
    max_file_bytes: int
    max_total_bytes: int
    allow_archive_symlinks: bool


@dataclass(frozen=True)
class StableSnapshot:
    root: Path
    source_modes: dict[str, int]


def limits_for(profile: str) -> SnapshotLimits:
    if profile == "archive":
        return SnapshotLimits(
            ARCHIVE_MAX_ENTRIES,
            ARCHIVE_MAX_FILE_BYTES,
            ARCHIVE_MAX_TOTAL_BYTES,
            True,
        )
    if profile == "app":
        return SnapshotLimits(
            APP_MAX_ENTRIES,
            APP_MAX_FILE_BYTES,
            APP_MAX_TOTAL_BYTES,
            False,
        )
    fail("snapshot profile must be archive or app")


def state_identity(value: os.stat_result) -> tuple[int, ...]:
    return (
        value.st_dev,
        value.st_ino,
        value.st_mode,
        value.st_size,
        value.st_mtime_ns,
        value.st_ctime_ns,
    )


def normalized_key(relative: str) -> str:
    if (
        not relative
        or "\\" in relative
        or any(ord(character) < 0x20 or ord(character) == 0x7F for character in relative)
    ):
        fail("source tree contains an unsafe path")
    return unicodedata.normalize("NFC", relative).casefold()


def stable_regular_file_bytes(
    path: Path,
    maximum_bytes: int = READ_MAX_BYTES,
) -> bytes:
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
    try:
        descriptor = os.open(path, flags)
    except OSError:
        fail("trusted regular file is missing, linked or unreadable")
    try:
        before = os.fstat(descriptor)
        if (
            not stat.S_ISREG(before.st_mode)
            or before.st_size < 0
            or before.st_size > maximum_bytes
        ):
            fail("trusted regular file type or size is invalid")
        chunks: list[bytes] = []
        copied = 0
        while True:
            chunk = os.read(descriptor, min(COPY_CHUNK_BYTES, maximum_bytes + 1))
            if not chunk:
                break
            copied += len(chunk)
            if copied > before.st_size or copied > maximum_bytes:
                fail("trusted regular file changed while being read")
            chunks.append(chunk)
        after = os.fstat(descriptor)
        try:
            current = os.lstat(path)
        except OSError:
            fail("trusted regular file path changed while being read")
        if (
            copied != before.st_size
            or state_identity(before) != state_identity(after)
            or state_identity(after) != state_identity(current)
        ):
            fail("trusted regular file changed while being read")
        return b"".join(chunks)
    finally:
        os.close(descriptor)


def stable_file_sha256(path: Path, maximum_bytes: int) -> str:
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
    try:
        descriptor = os.open(path, flags)
    except OSError:
        fail("regular file is missing, linked or unreadable")
    digest = hashlib.sha256()
    copied = 0
    try:
        before = os.fstat(descriptor)
        if (
            not stat.S_ISREG(before.st_mode)
            or before.st_size < 0
            or before.st_size > maximum_bytes
        ):
            fail("regular file type or size is invalid")
        while True:
            chunk = os.read(descriptor, COPY_CHUNK_BYTES)
            if not chunk:
                break
            copied += len(chunk)
            if copied > before.st_size or copied > maximum_bytes:
                fail("regular file changed while being hashed")
            digest.update(chunk)
        after = os.fstat(descriptor)
        try:
            current = os.lstat(path)
        except OSError:
            fail("regular file path changed while being hashed")
        if (
            copied != before.st_size
            or state_identity(before) != state_identity(after)
            or state_identity(after) != state_identity(current)
        ):
            fail("regular file changed while being hashed")
        return digest.hexdigest()
    finally:
        os.close(descriptor)


def _entry_snapshot(directory_fd: int) -> list[tuple[str, os.stat_result]]:
    try:
        names = sorted(os.listdir(directory_fd))
    except OSError:
        fail("source directory cannot be enumerated")
    entries: list[tuple[str, os.stat_result]] = []
    for name in names:
        try:
            value = os.stat(name, dir_fd=directory_fd, follow_symlinks=False)
        except OSError:
            fail("source directory entry changed during enumeration")
        entries.append((name, value))
    return entries


def _entry_identities(
    entries: list[tuple[str, os.stat_result]],
) -> list[tuple[str, tuple[int, ...]]]:
    return [(name, state_identity(value)) for name, value in entries]


def _approved_archive_symlink(relative: str, target: str) -> bool:
    if (
        not target
        or "\x00" in target
        or "\\" in target
        or Path(target).is_absolute()
        or any(ord(character) < 0x20 or ord(character) == 0x7F for character in target)
    ):
        return False
    normalized_parts: list[str] = []
    for part in (Path(relative).parent / target).parts:
        if part in {"", "."}:
            continue
        if part == "..":
            if not normalized_parts:
                return False
            normalized_parts.pop()
        else:
            normalized_parts.append(part)
    normalized_target = Path(*normalized_parts).as_posix()
    return any(
        relative.startswith(prefix) and normalized_target.startswith(prefix)
        for prefix in APPROVED_ARCHIVE_SYMLINK_PREFIXES
    )


class _SnapshotBuilder:
    def __init__(self, profile: str) -> None:
        self.limits = limits_for(profile)
        self.seen: set[str] = set()
        self.source_modes: dict[str, int] = {".": 0}
        self.entry_count = 0
        self.total_bytes = 0

    def copy_directory(
        self,
        source_fd: int,
        destination_fd: int,
        relative_parent: str,
    ) -> None:
        directory_before = os.fstat(source_fd)
        if not stat.S_ISDIR(directory_before.st_mode):
            fail("source directory descriptor changed type")
        initial_entries = _entry_snapshot(source_fd)
        initial_identities = _entry_identities(initial_entries)
        local_keys: set[str] = set()
        for name, _ in initial_entries:
            relative = name if not relative_parent else f"{relative_parent}/{name}"
            key = normalized_key(relative)
            if key in self.seen or key in local_keys:
                fail("source tree contains a Unicode or case-colliding path")
            local_keys.add(key)
        self.seen.update(local_keys)

        for name, initial in initial_entries:
            relative = name if not relative_parent else f"{relative_parent}/{name}"
            self.entry_count += 1
            if self.entry_count > self.limits.max_entries:
                fail("source tree contains too many entries")
            self.source_modes[relative] = stat.S_IMODE(initial.st_mode)
            if stat.S_ISDIR(initial.st_mode):
                try:
                    child_source_fd = os.open(
                        name,
                        os.O_RDONLY
                        | getattr(os, "O_DIRECTORY", 0)
                        | getattr(os, "O_NOFOLLOW", 0),
                        dir_fd=source_fd,
                    )
                except OSError:
                    fail("source subdirectory changed or became linked")
                try:
                    if state_identity(os.fstat(child_source_fd)) != state_identity(initial):
                        fail("source subdirectory changed before snapshot")
                    try:
                        os.mkdir(name, 0o700, dir_fd=destination_fd)
                        child_destination_fd = os.open(
                            name,
                            os.O_RDONLY
                            | getattr(os, "O_DIRECTORY", 0)
                            | getattr(os, "O_NOFOLLOW", 0),
                            dir_fd=destination_fd,
                        )
                    except OSError:
                        fail("private snapshot destination changed unexpectedly")
                    try:
                        self.copy_directory(
                            child_source_fd,
                            child_destination_fd,
                            relative,
                        )
                        os.fchmod(child_destination_fd, stat.S_IMODE(initial.st_mode))
                    finally:
                        os.close(child_destination_fd)
                finally:
                    os.close(child_source_fd)
            elif stat.S_ISREG(initial.st_mode):
                if initial.st_size < 0 or initial.st_size > self.limits.max_file_bytes:
                    fail("source file size is outside the allowed range")
                self.total_bytes += initial.st_size
                if self.total_bytes > self.limits.max_total_bytes:
                    fail("source tree total size exceeds the allowed range")
                self._copy_file(
                    source_fd,
                    destination_fd,
                    name,
                    initial,
                )
            elif stat.S_ISLNK(initial.st_mode):
                if not self.limits.allow_archive_symlinks:
                    fail("source app tree contains a symbolic link")
                try:
                    target = os.readlink(name, dir_fd=source_fd)
                except OSError:
                    fail("source symbolic link changed while being read")
                if not _approved_archive_symlink(relative, target):
                    fail("source archive contains a symbolic link outside the approved boundary")
                try:
                    os.symlink(target, name, dir_fd=destination_fd)
                except OSError:
                    fail("private snapshot symbolic link cannot be created")
                try:
                    current = os.stat(name, dir_fd=source_fd, follow_symlinks=False)
                    copied = os.stat(name, dir_fd=destination_fd, follow_symlinks=False)
                except OSError:
                    fail("source symbolic link changed during snapshot")
                if (
                    state_identity(current) != state_identity(initial)
                    or not stat.S_ISLNK(copied.st_mode)
                    or os.readlink(name, dir_fd=destination_fd) != target
                ):
                    fail("source symbolic link changed during snapshot")
            else:
                fail("source tree contains a FIFO, socket, device or special file")

            try:
                current = os.stat(name, dir_fd=source_fd, follow_symlinks=False)
            except OSError:
                fail("source entry disappeared during snapshot")
            if state_identity(current) != state_identity(initial):
                fail("source entry changed during snapshot")

        final_entries = _entry_snapshot(source_fd)
        directory_after = os.fstat(source_fd)
        if (
            initial_identities != _entry_identities(final_entries)
            or state_identity(directory_before) != state_identity(directory_after)
        ):
            fail("source directory changed during snapshot")

    def _copy_file(
        self,
        source_directory_fd: int,
        destination_directory_fd: int,
        name: str,
        initial: os.stat_result,
    ) -> None:
        try:
            source_fd = os.open(
                name,
                os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0),
                dir_fd=source_directory_fd,
            )
        except OSError:
            fail("source file changed or became linked")
        destination_fd = -1
        copied = 0
        try:
            before = os.fstat(source_fd)
            if (
                state_identity(before) != state_identity(initial)
                or not stat.S_ISREG(before.st_mode)
            ):
                fail("source file changed before snapshot")
            try:
                destination_fd = os.open(
                    name,
                    os.O_WRONLY
                    | os.O_CREAT
                    | os.O_EXCL
                    | getattr(os, "O_NOFOLLOW", 0),
                    stat.S_IMODE(initial.st_mode) or 0o400,
                    dir_fd=destination_directory_fd,
                )
            except OSError:
                fail("private snapshot destination changed unexpectedly")
            while True:
                chunk = os.read(source_fd, COPY_CHUNK_BYTES)
                if not chunk:
                    break
                copied += len(chunk)
                if copied > before.st_size or copied > self.limits.max_file_bytes:
                    fail("source file changed size during snapshot")
                view = memoryview(chunk)
                while view:
                    written = os.write(destination_fd, view)
                    if written <= 0:
                        fail("private snapshot write failed")
                    view = view[written:]
            os.fsync(destination_fd)
            os.fchmod(destination_fd, stat.S_IMODE(initial.st_mode))
            after = os.fstat(source_fd)
            if copied != before.st_size or state_identity(before) != state_identity(after):
                fail("source file changed during snapshot")
        finally:
            if destination_fd >= 0:
                os.close(destination_fd)
            os.close(source_fd)


def _open_stable_source_root(source: Path) -> tuple[int, int, os.stat_result, os.stat_result]:
    if not source.is_absolute() or source.name in {"", ".", ".."}:
        fail("source root must be one absolute directory path")
    parent = source.parent
    try:
        parent_fd = os.open(
            parent,
            os.O_RDONLY
            | getattr(os, "O_DIRECTORY", 0)
            | getattr(os, "O_NOFOLLOW", 0),
        )
        parent_state = os.fstat(parent_fd)
        source_fd = os.open(
            source.name,
            os.O_RDONLY
            | getattr(os, "O_DIRECTORY", 0)
            | getattr(os, "O_NOFOLLOW", 0),
            dir_fd=parent_fd,
        )
        source_state = os.fstat(source_fd)
    except OSError:
        try:
            os.close(parent_fd)
        except (NameError, OSError):
            pass
        fail("source root or its parent is missing, linked or unreadable")
    if not stat.S_ISDIR(source_state.st_mode):
        os.close(source_fd)
        os.close(parent_fd)
        fail("source root is not a directory")
    return parent_fd, source_fd, parent_state, source_state


def _verify_source_root_path(
    source: Path,
    parent_fd: int,
    parent_state: os.stat_result,
    source_state: os.stat_result,
) -> None:
    try:
        current_parent_fd_state = os.fstat(parent_fd)
        current_parent_path_state = os.lstat(source.parent)
        current_source = os.stat(
            source.name,
            dir_fd=parent_fd,
            follow_symlinks=False,
        )
    except OSError:
        fail("source root or parent path changed during snapshot")
    if (
        state_identity(parent_state) != state_identity(current_parent_fd_state)
        or state_identity(current_parent_fd_state) != state_identity(current_parent_path_state)
        or state_identity(source_state) != state_identity(current_source)
    ):
        fail("source root or parent path changed during snapshot")


@contextlib.contextmanager
def sealed_tree_snapshot(
    source: Path,
    profile: str,
    staging_parent: Path | None = None,
) -> Iterator[StableSnapshot]:
    limits_for(profile)
    source = Path(os.path.abspath(source))
    if staging_parent is not None:
        staging_parent = Path(os.path.abspath(staging_parent))
        if not staging_parent.is_dir() or staging_parent.is_symlink():
            fail("snapshot staging parent is missing or linked")
    with tempfile.TemporaryDirectory(
        prefix=".wenxintong-app2-sealed.",
        dir=staging_parent,
    ) as directory:
        private_root = Path(directory)
        private_state = os.lstat(private_root)
        if not stat.S_ISDIR(private_state.st_mode) or stat.S_IMODE(private_state.st_mode) != 0o700:
            fail("private snapshot staging root is not mode 0700")
        snapshot_root = private_root / "tree"
        os.mkdir(snapshot_root, 0o700)
        destination_fd = os.open(
            snapshot_root,
            os.O_RDONLY
            | getattr(os, "O_DIRECTORY", 0)
            | getattr(os, "O_NOFOLLOW", 0),
        )
        parent_fd, source_fd, parent_state, source_state = _open_stable_source_root(source)
        builder = _SnapshotBuilder(profile)
        builder.source_modes["."] = stat.S_IMODE(source_state.st_mode)
        try:
            builder.copy_directory(source_fd, destination_fd, "")
            os.fchmod(destination_fd, stat.S_IMODE(source_state.st_mode))
            _verify_source_root_path(
                source,
                parent_fd,
                parent_state,
                source_state,
            )
        finally:
            os.close(source_fd)
            os.close(parent_fd)
            os.close(destination_fd)
        yield StableSnapshot(snapshot_root, dict(builder.source_modes))


def _path_matches_state(path: Path, expected: os.stat_result) -> bool:
    try:
        current = os.lstat(path)
    except OSError:
        return False
    return (
        current.st_dev == expected.st_dev
        and current.st_ino == expected.st_ino
        and stat.S_IFMT(current.st_mode) == stat.S_IFMT(expected.st_mode)
    )


def _renameat_exchange(
    left_parent_fd: int,
    left_name: str,
    right_parent_fd: int,
    right_name: str,
) -> None:
    libc = ctypes.CDLL(None, use_errno=True)
    left_bytes = os.fsencode(left_name)
    right_bytes = os.fsencode(right_name)
    if sys.platform == "darwin":
        rename = libc.renameatx_np
        rename.argtypes = [
            ctypes.c_int,
            ctypes.c_char_p,
            ctypes.c_int,
            ctypes.c_char_p,
            ctypes.c_uint,
        ]
        rename.restype = ctypes.c_int
        result = rename(
            left_parent_fd,
            left_bytes,
            right_parent_fd,
            right_bytes,
            0x00000002,
        )
    elif sys.platform.startswith("linux") and hasattr(libc, "renameat2"):
        rename = libc.renameat2
        rename.argtypes = [
            ctypes.c_int,
            ctypes.c_char_p,
            ctypes.c_int,
            ctypes.c_char_p,
            ctypes.c_uint,
        ]
        rename.restype = ctypes.c_int
        result = rename(
            left_parent_fd,
            left_bytes,
            right_parent_fd,
            right_bytes,
            0x00000002,
        )
    else:
        raise OSError(
            errno.ENOTSUP,
            "atomic directory exchange is unavailable",
        )
    if result != 0:
        error = ctypes.get_errno()
        raise OSError(error, os.strerror(error), right_name)


def _same_directory_identity(
    current: os.stat_result,
    expected: os.stat_result,
) -> bool:
    return (
        stat.S_ISDIR(current.st_mode)
        and current.st_dev == expected.st_dev
        and current.st_ino == expected.st_ino
    )


def _same_promoted_root_state(
    current: os.stat_result,
    expected: os.stat_result,
) -> bool:
    return (
        stat.S_ISDIR(current.st_mode)
        and current.st_dev == expected.st_dev
        and current.st_ino == expected.st_ino
        and stat.S_IMODE(current.st_mode) == stat.S_IMODE(expected.st_mode)
        and current.st_size == expected.st_size
        and current.st_mtime_ns == expected.st_mtime_ns
    )


def _create_held_placeholder(
    parent_fd: int,
    name: str,
) -> tuple[int, os.stat_result]:
    os.mkdir(name, 0o700, dir_fd=parent_fd)
    created = os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
    descriptor = -1
    try:
        descriptor = os.open(
            name,
            os.O_RDONLY
            | getattr(os, "O_DIRECTORY", 0)
            | getattr(os, "O_NOFOLLOW", 0),
            dir_fd=parent_fd,
        )
        os.fchmod(descriptor, 0o700)
        state = os.fstat(descriptor)
        current = os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
        if (
            not stat.S_ISDIR(created.st_mode)
            or not stat.S_ISDIR(state.st_mode)
            or stat.S_IMODE(state.st_mode) != 0o700
            or created.st_dev != state.st_dev
            or created.st_ino != state.st_ino
            or state_identity(state) != state_identity(current)
        ):
            raise RuntimeError("promotion placeholder identity is invalid")
        return descriptor, state
    except BaseException:
        if descriptor >= 0:
            try:
                held = os.fstat(descriptor)
                current = os.stat(
                    name,
                    dir_fd=parent_fd,
                    follow_symlinks=False,
                )
                if (
                    stat.S_ISDIR(current.st_mode)
                    and current.st_dev == created.st_dev == held.st_dev
                    and current.st_ino == created.st_ino == held.st_ino
                    and not os.listdir(descriptor)
                ):
                    os.fchmod(descriptor, 0o700)
                    os.rmdir(name, dir_fd=parent_fd)
            except OSError:
                pass
            finally:
                os.close(descriptor)
        else:
            try:
                current = os.stat(
                    name,
                    dir_fd=parent_fd,
                    follow_symlinks=False,
                )
                if (
                    stat.S_ISDIR(current.st_mode)
                    and current.st_dev == created.st_dev
                    and current.st_ino == created.st_ino
                ):
                    os.rmdir(name, dir_fd=parent_fd)
            except OSError:
                pass
        raise


def _reserve_private_quarantine(
    destination_parent_fd: int,
) -> tuple[str, int]:
    directory_flags = (
        os.O_RDONLY
        | getattr(os, "O_DIRECTORY", 0)
        | getattr(os, "O_NOFOLLOW", 0)
    )
    for _ in range(32):
        name = f".wenxintong-app2-quarantine.{secrets.token_hex(16)}"
        try:
            os.mkdir(name, 0o700, dir_fd=destination_parent_fd)
        except FileExistsError:
            continue
        except OSError as error:
            raise RuntimeError("cannot reserve private promotion quarantine") from error
        try:
            created = os.stat(
                name,
                dir_fd=destination_parent_fd,
                follow_symlinks=False,
            )
        except OSError as error:
            raise RuntimeError(
                "cannot bind the created promotion quarantine inode"
            ) from error
        try:
            descriptor = os.open(
                name,
                directory_flags,
                dir_fd=destination_parent_fd,
            )
        except OSError as error:
            try:
                current = os.stat(
                    name,
                    dir_fd=destination_parent_fd,
                    follow_symlinks=False,
                )
                if (
                    stat.S_ISDIR(current.st_mode)
                    and current.st_dev == created.st_dev
                    and current.st_ino == created.st_ino
                ):
                    os.rmdir(name, dir_fd=destination_parent_fd)
            except OSError:
                pass
            raise RuntimeError("cannot open private promotion quarantine") from error
        state = os.fstat(descriptor)
        current = os.stat(
            name,
            dir_fd=destination_parent_fd,
            follow_symlinks=False,
        )
        if (
            not stat.S_ISDIR(created.st_mode)
            or not stat.S_ISDIR(state.st_mode)
            or stat.S_IMODE(state.st_mode) != 0o700
            or created.st_dev != state.st_dev
            or created.st_ino != state.st_ino
            or current.st_dev != state.st_dev
            or current.st_ino != state.st_ino
        ):
            try:
                if (
                    stat.S_ISDIR(current.st_mode)
                    and current.st_dev == created.st_dev == state.st_dev
                    and current.st_ino == created.st_ino == state.st_ino
                    and not os.listdir(descriptor)
                ):
                    os.rmdir(name, dir_fd=destination_parent_fd)
            finally:
                os.close(descriptor)
            raise RuntimeError("private promotion quarantine is not mode 0700")
        return name, descriptor
    raise RuntimeError("cannot reserve a unique private promotion quarantine")


def _safe_remove_tree_contents_fd(
    directory_fd: int,
    remaining_entries: list[int],
) -> None:
    # POSIX has no inode-conditioned unlinkat/rmdirat. Release workflows must
    # therefore run in an isolated CI account/workspace without an adversarial
    # same-UID process. Every traversal remains fd-relative, nofollow, bounded,
    # and identity-checked; transaction boundary names use atomic exchange.
    os.fchmod(directory_fd, 0o700)
    while True:
        names = sorted(os.listdir(directory_fd))
        if not names:
            return
        remaining_entries[0] -= len(names)
        if remaining_entries[0] < 0:
            raise RuntimeError(
                "quarantined promotion exceeds the cleanup entry limit"
            )
        for name in names:
            state = os.stat(
                name,
                dir_fd=directory_fd,
                follow_symlinks=False,
            )
            if stat.S_ISDIR(state.st_mode):
                child_fd = os.open(
                    name,
                    os.O_RDONLY
                    | getattr(os, "O_DIRECTORY", 0)
                    | getattr(os, "O_NOFOLLOW", 0),
                    dir_fd=directory_fd,
                )
                try:
                    held = os.fstat(child_fd)
                    if held.st_dev != state.st_dev or held.st_ino != state.st_ino:
                        raise RuntimeError(
                            "quarantined directory identity changed during cleanup"
                        )
                    _safe_remove_tree_contents_fd(child_fd, remaining_entries)
                    current = os.stat(
                        name,
                        dir_fd=directory_fd,
                        follow_symlinks=False,
                    )
                    if (
                        current.st_dev != held.st_dev
                        or current.st_ino != held.st_ino
                    ):
                        raise RuntimeError(
                            "quarantined directory name changed before removal"
                        )
                    os.rmdir(name, dir_fd=directory_fd)
                finally:
                    os.close(child_fd)
            elif stat.S_ISREG(state.st_mode) or stat.S_ISLNK(state.st_mode):
                os.unlink(name, dir_fd=directory_fd)
            else:
                raise RuntimeError(
                    "quarantined promotion contains an unsafe special entry"
                )


def _safe_remove_expected_directory(
    parent_fd: int,
    name: str,
    expected: os.stat_result,
) -> None:
    directory_fd = os.open(
        name,
        os.O_RDONLY
        | getattr(os, "O_DIRECTORY", 0)
        | getattr(os, "O_NOFOLLOW", 0),
        dir_fd=parent_fd,
    )
    try:
        held = os.fstat(directory_fd)
        if held.st_dev != expected.st_dev or held.st_ino != expected.st_ino:
            raise RuntimeError("refusing to remove an unexpected promotion inode")
        _safe_remove_tree_contents_fd(
            directory_fd,
            [ARCHIVE_MAX_ENTRIES],
        )
        current = os.stat(
            name,
            dir_fd=parent_fd,
            follow_symlinks=False,
        )
        if current.st_dev != held.st_dev or current.st_ino != held.st_ino:
            raise RuntimeError(
                "quarantined promotion name changed before root removal"
            )
        os.rmdir(name, dir_fd=parent_fd)
    finally:
        os.close(directory_fd)


def _remove_reserved_quarantine(
    destination_parent_fd: int,
    quarantine_name: str,
    quarantine_fd: int,
) -> None:
    held = os.fstat(quarantine_fd)
    current = os.stat(
        quarantine_name,
        dir_fd=destination_parent_fd,
        follow_symlinks=False,
    )
    if (
        not stat.S_ISDIR(current.st_mode)
        or current.st_dev != held.st_dev
        or current.st_ino != held.st_ino
        or os.listdir(quarantine_fd)
    ):
        raise RuntimeError(
            "refusing to remove a replaced or non-empty promotion quarantine"
        )
    os.rmdir(quarantine_name, dir_fd=destination_parent_fd)


def _entry_is_missing(parent_fd: int, name: str) -> bool:
    try:
        os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
    except FileNotFoundError:
        return True
    return False


def _retract_failed_promotion(
    destination_parent_fd: int,
    destination_name: str,
    quarantine_fd: int,
    promoted_state: os.stat_result,
) -> None:
    current_formal = os.stat(
        destination_name,
        dir_fd=destination_parent_fd,
        follow_symlinks=False,
    )
    if (
        current_formal.st_dev != promoted_state.st_dev
        or current_formal.st_ino != promoted_state.st_ino
    ):
        raise RuntimeError(
            "formal destination no longer names the expected promoted inode"
        )
    quarantine_name = "retract-placeholder"
    placeholder_fd, placeholder_state = _create_held_placeholder(
        quarantine_fd,
        quarantine_name,
    )
    try:
        _renameat_exchange(
            destination_parent_fd,
            destination_name,
            quarantine_fd,
            quarantine_name,
        )
    except BaseException:
        try:
            os.fchmod(placeholder_fd, 0o700)
            _safe_remove_expected_directory(
                quarantine_fd,
                quarantine_name,
                placeholder_state,
            )
        finally:
            os.close(placeholder_fd)
        raise

    quarantined = os.stat(
        quarantine_name,
        dir_fd=quarantine_fd,
        follow_symlinks=False,
    )
    formal_placeholder = os.stat(
        destination_name,
        dir_fd=destination_parent_fd,
        follow_symlinks=False,
    )
    if (
        quarantined.st_dev != promoted_state.st_dev
        or quarantined.st_ino != promoted_state.st_ino
        or formal_placeholder.st_dev != placeholder_state.st_dev
        or formal_placeholder.st_ino != placeholder_state.st_ino
    ):
        try:
            _renameat_exchange(
                destination_parent_fd,
                destination_name,
                quarantine_fd,
                quarantine_name,
            )
        except BaseException as restore_error:
            os.close(placeholder_fd)
            raise RuntimeError(
                "failed to restore an unknown formal destination after exchange"
            ) from restore_error
        restored_placeholder = os.stat(
            quarantine_name,
            dir_fd=quarantine_fd,
            follow_symlinks=False,
        )
        if (
            restored_placeholder.st_dev != placeholder_state.st_dev
            or restored_placeholder.st_ino != placeholder_state.st_ino
        ):
            os.close(placeholder_fd)
            raise RuntimeError(
                "formal destination exchange-back did not restore the placeholder"
            )
        os.fchmod(placeholder_fd, 0o700)
        _safe_remove_expected_directory(
            quarantine_fd,
            quarantine_name,
            placeholder_state,
        )
        os.close(placeholder_fd)
        raise RuntimeError(
            "formal destination changed before exact-inode retraction"
        )

    try:
        os.fchmod(placeholder_fd, 0o700)
        _safe_remove_expected_directory(
            destination_parent_fd,
            destination_name,
            placeholder_state,
        )
        _safe_remove_expected_directory(
            quarantine_fd,
            quarantine_name,
            promoted_state,
        )
    finally:
        os.close(placeholder_fd)


def _promote_directory_transaction(
    source: Path,
    destination: Path,
    *,
    profile: str | None = None,
    expected_digest: str | None = None,
    validator: Callable[[int], object] | None = None,
) -> None:
    if (
        not source.is_absolute()
        or not destination.is_absolute()
        or source.name in {"", ".", ".."}
        or destination.name in {"", ".", ".."}
        or (profile is None) != (expected_digest is None)
    ):
        fail("atomic directory promotion transaction paths are invalid")
    directory_flags = (
        os.O_RDONLY
        | getattr(os, "O_DIRECTORY", 0)
        | getattr(os, "O_NOFOLLOW", 0)
    )
    try:
        source_parent_fd = os.open(source.parent, directory_flags)
        destination_parent_fd = os.open(destination.parent, directory_flags)
    except OSError:
        try:
            os.close(source_parent_fd)
        except (NameError, OSError):
            pass
        fail("atomic directory promotion parent is unsafe")
    source_fd = -1
    quarantine_fd = -1
    quarantine_name = ""
    promotion_placeholder_fd = -1
    promotion_placeholder_state: os.stat_result | None = None
    promotion_placeholder_location = ""
    promoted = False
    transaction_succeeded = False
    promoted_state: os.stat_result | None = None
    try:
        source_parent_state = os.fstat(source_parent_fd)
        destination_parent_state = os.fstat(destination_parent_fd)
        if (
            not _path_matches_state(source.parent, source_parent_state)
            or not _path_matches_state(destination.parent, destination_parent_state)
        ):
            fail("atomic directory promotion parent identity changed at entry")
        source_fd = os.open(
            source.name,
            directory_flags,
            dir_fd=source_parent_fd,
        )
        source_state = os.fstat(source_fd)
        current_source = os.stat(
            source.name,
            dir_fd=source_parent_fd,
            follow_symlinks=False,
        )
        if (
            not stat.S_ISDIR(source_state.st_mode)
            or state_identity(source_state) != state_identity(current_source)
        ):
            fail("atomic directory promotion source identity changed at entry")
        if not _entry_is_missing(destination_parent_fd, destination.name):
            fail("atomic directory promotion destination already exists")
        quarantine_name, quarantine_fd = _reserve_private_quarantine(
            destination_parent_fd
        )

        if profile is not None:
            before_digest = _snapshot_content_digest_fd(source_fd, profile)
            if before_digest != expected_digest:
                fail("final promotion digest changed before rename")
        before_evidence = validator(source_fd) if validator is not None else None
        root_before_rename = os.fstat(source_fd)

        (
            promotion_placeholder_fd,
            promotion_placeholder_state,
        ) = _create_held_placeholder(
            destination_parent_fd,
            destination.name,
        )
        promotion_placeholder_location = "destination"
        _renameat_exchange(
            source_parent_fd,
            source.name,
            destination_parent_fd,
            destination.name,
        )
        promoted = True
        promotion_placeholder_location = "source"
        promoted_state = os.fstat(source_fd)
        delivered = os.stat(
            destination.name,
            dir_fd=destination_parent_fd,
            follow_symlinks=False,
        )
        source_opposite = os.stat(
            source.name,
            dir_fd=source_parent_fd,
            follow_symlinks=False,
        )
        if (
            delivered.st_dev != promoted_state.st_dev
            or delivered.st_ino != promoted_state.st_ino
            or source_opposite.st_dev != promotion_placeholder_state.st_dev
            or source_opposite.st_ino != promotion_placeholder_state.st_ino
        ):
            try:
                _renameat_exchange(
                    source_parent_fd,
                    source.name,
                    destination_parent_fd,
                    destination.name,
                )
            except BaseException as restore_error:
                fail(
                    "source replacement exchange could not be restored: "
                    f"{restore_error}"
                )
            promoted = False
            promotion_placeholder_location = "destination"
            restored_placeholder = os.stat(
                destination.name,
                dir_fd=destination_parent_fd,
                follow_symlinks=False,
            )
            if (
                restored_placeholder.st_dev
                != promotion_placeholder_state.st_dev
                or restored_placeholder.st_ino
                != promotion_placeholder_state.st_ino
            ):
                fail("source replacement exchange-back lost the placeholder")
            os.fchmod(promotion_placeholder_fd, 0o700)
            _safe_remove_expected_directory(
                destination_parent_fd,
                destination.name,
                promotion_placeholder_state,
            )
            promotion_placeholder_location = ""
            fail("source basename no longer names the held promotion inode")

        if (
            not _same_promoted_root_state(promoted_state, root_before_rename)
            or not _same_directory_identity(
                os.fstat(source_parent_fd),
                source_parent_state,
            )
            or not _same_directory_identity(
                os.fstat(destination_parent_fd),
                destination_parent_state,
            )
            or not _path_matches_state(source.parent, source_parent_state)
            or not _path_matches_state(destination.parent, destination_parent_state)
        ):
            fail("atomic promotion inode, state or parent changed during rename")
        os.fchmod(promotion_placeholder_fd, 0o700)
        _safe_remove_expected_directory(
            source_parent_fd,
            source.name,
            promotion_placeholder_state,
        )
        promotion_placeholder_location = ""
        if profile is not None and (
            _snapshot_content_digest_fd(source_fd, profile) != expected_digest
        ):
            fail("final promotion digest changed across rename")
        if validator is not None and validator(source_fd) != before_evidence:
            fail("verified promotion evidence changed across rename")

        delivered_after = os.stat(
            destination.name,
            dir_fd=destination_parent_fd,
            follow_symlinks=False,
        )
        root_after = os.fstat(source_fd)
        if (
            delivered_after.st_dev != promoted_state.st_dev
            or delivered_after.st_ino != promoted_state.st_ino
            or not _same_promoted_root_state(root_after, promoted_state)
            or not _same_directory_identity(
                os.fstat(source_parent_fd),
                source_parent_state,
            )
            or not _same_directory_identity(
                os.fstat(destination_parent_fd),
                destination_parent_state,
            )
            or not _path_matches_state(source.parent, source_parent_state)
            or not _path_matches_state(destination.parent, destination_parent_state)
        ):
            fail("promoted directory changed during post-promotion verification")
        if profile is not None and (
            _snapshot_content_digest_fd(source_fd, profile) != expected_digest
        ):
            fail("promoted directory digest changed after verification")
        if validator is not None and validator(source_fd) != before_evidence:
            fail("promoted delivery evidence changed after verification")

        _remove_reserved_quarantine(
            destination_parent_fd,
            quarantine_name,
            quarantine_fd,
        )
        transaction_succeeded = True
    except BaseException as transaction_error:
        if promoted and promoted_state is not None:
            try:
                _retract_failed_promotion(
                    destination_parent_fd,
                    destination.name,
                    quarantine_fd,
                    promoted_state,
                )
            except BaseException as cleanup_error:
                fail(
                    "post-promotion failure could not be safely retracted: "
                    f"{cleanup_error}"
                )
        raise transaction_error
    finally:
        quarantine_cleanup_error: OSError | None = None
        placeholder_cleanup_error: BaseException | None = None
        if (
            promotion_placeholder_location
            and promotion_placeholder_state is not None
        ):
            try:
                if promotion_placeholder_fd >= 0:
                    os.fchmod(promotion_placeholder_fd, 0o700)
                if promotion_placeholder_location == "source":
                    _safe_remove_expected_directory(
                        source_parent_fd,
                        source.name,
                        promotion_placeholder_state,
                    )
                elif promotion_placeholder_location == "destination":
                    _safe_remove_expected_directory(
                        destination_parent_fd,
                        destination.name,
                        promotion_placeholder_state,
                    )
                else:
                    raise RuntimeError(
                        "promotion placeholder location is invalid"
                    )
            except BaseException as error:
                placeholder_cleanup_error = error
        if (
            quarantine_name
            and not transaction_succeeded
        ):
            try:
                _remove_reserved_quarantine(
                    destination_parent_fd,
                    quarantine_name,
                    quarantine_fd,
                )
            except (OSError, RuntimeError) as error:
                quarantine_cleanup_error = error
        if quarantine_fd >= 0:
            os.close(quarantine_fd)
        if promotion_placeholder_fd >= 0:
            os.close(promotion_placeholder_fd)
        if source_fd >= 0:
            os.close(source_fd)
        os.close(destination_parent_fd)
        os.close(source_parent_fd)
        if quarantine_cleanup_error is not None:
            fail(
                "private promotion quarantine cleanup is uncertain after failure"
            )
        if placeholder_cleanup_error is not None:
            fail(
                "known promotion placeholder cleanup is uncertain after failure"
            )


def copy_verified_file(
    source: Path,
    destination: Path,
    expected_sha256: str,
    maximum_bytes: int,
) -> str:
    if (
        len(expected_sha256) != 64
        or any(character not in "0123456789abcdef" for character in expected_sha256)
    ):
        fail("expected file digest is invalid")
    if destination.exists() or destination.is_symlink() or not destination.parent.is_dir():
        fail("verified file destination must be one new path")
    source_flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
    destination_flags = (
        os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0)
    )
    try:
        source_fd = os.open(source, source_flags)
        destination_fd = os.open(destination, destination_flags, 0o400)
    except OSError:
        try:
            os.close(source_fd)
        except (NameError, OSError):
            pass
        fail("verified file source or destination is unsafe")
    digest = hashlib.sha256()
    copied = 0
    try:
        before = os.fstat(source_fd)
        if (
            not stat.S_ISREG(before.st_mode)
            or before.st_size <= 0
            or before.st_size > maximum_bytes
        ):
            fail("verified file source type or size is invalid")
        while True:
            chunk = os.read(source_fd, COPY_CHUNK_BYTES)
            if not chunk:
                break
            copied += len(chunk)
            if copied > before.st_size or copied > maximum_bytes:
                fail("verified file changed while being copied")
            digest.update(chunk)
            view = memoryview(chunk)
            while view:
                written = os.write(destination_fd, view)
                if written <= 0:
                    fail("verified file copy failed")
                view = view[written:]
        os.fsync(destination_fd)
        after = os.fstat(source_fd)
        delivered = os.fstat(destination_fd)
        actual = digest.hexdigest()
        try:
            current_source = os.lstat(source)
            current_destination = os.lstat(destination)
        except OSError:
            fail("verified file path changed while being copied")
        if (
            copied != before.st_size
            or actual != expected_sha256
            or state_identity(before) != state_identity(after)
            or state_identity(after) != state_identity(current_source)
            or not stat.S_ISREG(delivered.st_mode)
            or delivered.st_size != copied
            or delivered.st_dev != current_destination.st_dev
            or delivered.st_ino != current_destination.st_ino
        ):
            fail("verified file identity or digest changed during copy")
        return actual
    except BaseException:
        try:
            destination.unlink()
        except FileNotFoundError:
            pass
        raise
    finally:
        os.close(destination_fd)
        os.close(source_fd)


def _descriptor_sha256(
    descriptor: int,
    maximum_bytes: int,
) -> tuple[str, os.stat_result]:
    before = os.fstat(descriptor)
    if (
        not stat.S_ISREG(before.st_mode)
        or before.st_size <= 0
        or before.st_size > maximum_bytes
    ):
        fail("delivery file type or size is invalid")
    os.lseek(descriptor, 0, os.SEEK_SET)
    digest = hashlib.sha256()
    copied = 0
    while True:
        chunk = os.read(descriptor, COPY_CHUNK_BYTES)
        if not chunk:
            break
        copied += len(chunk)
        if copied > before.st_size or copied > maximum_bytes:
            fail("delivery file changed while being hashed")
        digest.update(chunk)
    after = os.fstat(descriptor)
    if copied != before.st_size or state_identity(before) != state_identity(after):
        fail("delivery file changed while being hashed")
    return digest.hexdigest(), after


def _verified_delivery_evidence(
    directory_fd: int,
    ipa_sha256: str,
    evidence_sha256: str,
    maximum_ipa_bytes: int,
) -> tuple[tuple[str, tuple[int, ...]], ...]:
    expected_entries = [
        "APP2_IPA_VERIFICATION.json",
        "WenxintongApp2.ipa",
    ]
    directory_before = os.fstat(directory_fd)
    if sorted(os.listdir(directory_fd)) != expected_entries:
        fail("verified delivery directory has unexpected entries")
    results: list[tuple[str, tuple[int, ...]]] = []
    for name, expected_digest, maximum_bytes in (
        ("APP2_IPA_VERIFICATION.json", evidence_sha256, READ_MAX_BYTES),
        ("WenxintongApp2.ipa", ipa_sha256, maximum_ipa_bytes),
    ):
        descriptor = os.open(
            name,
            os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0),
            dir_fd=directory_fd,
        )
        try:
            actual, state = _descriptor_sha256(descriptor, maximum_bytes)
            current = os.stat(
                name,
                dir_fd=directory_fd,
                follow_symlinks=False,
            )
            if actual != expected_digest or state_identity(state) != state_identity(
                current
            ):
                fail("verified delivery digest or inode changed")
            results.append((name, state_identity(state)))
        finally:
            os.close(descriptor)
    if (
        sorted(os.listdir(directory_fd)) != expected_entries
        or state_identity(directory_before) != state_identity(os.fstat(directory_fd))
    ):
        fail("verified delivery directory changed during validation")
    return tuple(results)


def promote_verified_delivery(
    source: Path,
    destination: Path,
    ipa_sha256: str,
    evidence_sha256: str,
    maximum_ipa_bytes: int,
) -> None:
    if (
        not source.is_absolute()
        or not destination.is_absolute()
        or destination.exists()
        or destination.is_symlink()
    ):
        fail("verified delivery promotion paths are invalid")

    def validate(directory_fd: int) -> object:
        return _verified_delivery_evidence(
            directory_fd,
            ipa_sha256,
            evidence_sha256,
            maximum_ipa_bytes,
        )

    _promote_directory_transaction(
        source,
        destination,
        validator=validate,
    )


def run_snapshot_command(
    command: list[str],
    snapshot_root: Path,
) -> subprocess.CompletedProcess[bytes]:
    rendered = [
        str(snapshot_root) if value == "{snapshot}" else value
        for value in command
    ]
    environment = dict(os.environ)
    for name in (
        "APP2_SEALED_SNAPSHOT",
        "APP2_SEALED_SNAPSHOT_FD",
        "APP2_SEALED_SNAPSHOT_DEV",
        "APP2_SEALED_SNAPSHOT_INO",
        "APP2_INTERNAL_SEALED_WORKFLOW",
        "APP2_ARCHIVE_IS_SEALED_SNAPSHOT",
        "APP2_APP_IS_SEALED_SNAPSHOT",
    ):
        environment.pop(name, None)
    return subprocess.run(rendered, env=environment, check=False)


def _snapshot_content_digest_fd(root_fd: int, profile: str) -> str:
    limits = limits_for(profile)
    root_state = os.fstat(root_fd)
    if not stat.S_ISDIR(root_state.st_mode):
        fail("sealed snapshot root is not one directory")
    entries: list[tuple[str, bytes, int, int, bytes]] = []
    seen: set[str] = set()
    entry_count = 0
    total_bytes = 0

    def walk(directory_fd: int, prefix: str) -> None:
        nonlocal entry_count, total_bytes
        directory_before = os.fstat(directory_fd)
        names_before = sorted(os.listdir(directory_fd))
        for name in names_before:
            if (
                not name
                or name in {".", ".."}
                or "/" in name
                or "\\" in name
                or any(
                    ord(character) < 0x20 or ord(character) == 0x7F
                    for character in name
                )
            ):
                fail("sealed snapshot contains an unsafe entry name")
            relative = f"{prefix}/{name}" if prefix else name
            key = normalized_key(relative)
            if key in seen:
                fail("sealed snapshot contains a Unicode or case-colliding path")
            seen.add(key)
            entry_count += 1
            if entry_count > limits.max_entries:
                fail("sealed snapshot contains too many entries")
            state = os.stat(
                name,
                dir_fd=directory_fd,
                follow_symlinks=False,
            )
            mode = stat.S_IMODE(state.st_mode)
            if stat.S_ISDIR(state.st_mode):
                child_fd = os.open(
                    name,
                    os.O_RDONLY
                    | getattr(os, "O_DIRECTORY", 0)
                    | getattr(os, "O_NOFOLLOW", 0),
                    dir_fd=directory_fd,
                )
                try:
                    held = os.fstat(child_fd)
                    if state_identity(held) != state_identity(state):
                        fail("sealed snapshot directory identity changed")
                    entries.append((relative, b"D", mode, 0, b""))
                    walk(child_fd, relative)
                    current = os.stat(
                        name,
                        dir_fd=directory_fd,
                        follow_symlinks=False,
                    )
                    if state_identity(os.fstat(child_fd)) != state_identity(current):
                        fail("sealed snapshot directory changed during digest")
                finally:
                    os.close(child_fd)
                continue
            if stat.S_ISLNK(state.st_mode):
                target = os.readlink(name, dir_fd=directory_fd).encode("utf-8")
                current = os.stat(
                    name,
                    dir_fd=directory_fd,
                    follow_symlinks=False,
                )
                if state_identity(state) != state_identity(current):
                    fail("sealed snapshot symbolic link changed during digest")
                entries.append((relative, b"L", mode, len(target), target))
                continue
            if not stat.S_ISREG(state.st_mode):
                fail("sealed snapshot contains an unsupported entry")
            if state.st_size < 0 or state.st_size > limits.max_file_bytes:
                fail("sealed snapshot file size is outside the allowed range")
            total_bytes += state.st_size
            if total_bytes > limits.max_total_bytes:
                fail("sealed snapshot total size exceeds the allowed range")
            descriptor = os.open(
                name,
                os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0),
                dir_fd=directory_fd,
            )
            file_digest = hashlib.sha256()
            copied = 0
            try:
                before = os.fstat(descriptor)
                if state_identity(before) != state_identity(state):
                    fail("sealed snapshot file identity changed")
                while True:
                    chunk = os.read(descriptor, COPY_CHUNK_BYTES)
                    if not chunk:
                        break
                    copied += len(chunk)
                    if copied > before.st_size:
                        fail("sealed snapshot file grew during digest")
                    file_digest.update(chunk)
                after = os.fstat(descriptor)
                current = os.stat(
                    name,
                    dir_fd=directory_fd,
                    follow_symlinks=False,
                )
                if (
                    copied != before.st_size
                    or state_identity(before) != state_identity(after)
                    or state_identity(after) != state_identity(current)
                ):
                    fail("sealed snapshot file changed during digest")
            finally:
                os.close(descriptor)
            entries.append(
                (
                    relative,
                    b"F",
                    mode,
                    state.st_size,
                    file_digest.digest(),
                )
            )
        if (
            names_before != sorted(os.listdir(directory_fd))
            or state_identity(directory_before) != state_identity(os.fstat(directory_fd))
        ):
            fail("sealed snapshot directory changed during digest")

    walk(root_fd, "")
    root_after = os.fstat(root_fd)
    if state_identity(root_state) != state_identity(root_after):
        fail("sealed snapshot root changed during digest")
    digest = hashlib.sha256()
    digest.update(b"R")
    digest.update(stat.S_IMODE(root_state.st_mode).to_bytes(4, "big"))
    for relative, kind, mode, size, payload in sorted(entries):
        relative_bytes = relative.encode("utf-8")
        digest.update(kind)
        digest.update(mode.to_bytes(4, "big"))
        digest.update(len(relative_bytes).to_bytes(8, "big"))
        digest.update(relative_bytes)
        digest.update(size.to_bytes(8, "big"))
        digest.update(len(payload).to_bytes(8, "big"))
        digest.update(payload)
    return digest.hexdigest()


def _snapshot_content_digest(root: Path, profile: str) -> str:
    descriptor = os.open(
        root,
        os.O_RDONLY
        | getattr(os, "O_DIRECTORY", 0)
        | getattr(os, "O_NOFOLLOW", 0),
    )
    try:
        return _snapshot_content_digest_fd(descriptor, profile)
    finally:
        os.close(descriptor)


def promote_mutated_snapshot(
    profile: str,
    source: Path,
    destination: Path,
    mutate_command: list[str],
    verify_command: list[str],
) -> None:
    if (
        not destination.is_absolute()
        or destination.name in {"", ".", ".."}
        or destination.exists()
        or destination.is_symlink()
        or not mutate_command
        or not verify_command
    ):
        fail("promoted snapshot destination or fixed commands are invalid")
    with sealed_tree_snapshot(source, profile) as working:
        result = run_snapshot_command(mutate_command, working.root)
        if result.returncode != 0:
            raise SystemExit(result.returncode)
        with sealed_tree_snapshot(
            working.root,
            profile,
            staging_parent=destination.parent,
        ) as verification_input:
            expected_digest = _snapshot_content_digest(
                verification_input.root,
                profile,
            )
            result = run_snapshot_command(verify_command, verification_input.root)
            if result.returncode != 0:
                raise SystemExit(result.returncode)
            with sealed_tree_snapshot(
                verification_input.root,
                profile,
                staging_parent=destination.parent,
            ) as verified:
                if (
                    _snapshot_content_digest(verified.root, profile)
                    != expected_digest
                ):
                    fail("final snapshot changed during verification")
                _promote_directory_transaction(
                    verified.root,
                    destination,
                    profile=profile,
                    expected_digest=expected_digest,
                )


def command_main(arguments: list[str]) -> None:
    if len(arguments) >= 5 and arguments[0] == "exec" and arguments[3] == "--":
        profile = arguments[1]
        source = Path(arguments[2])
        command = arguments[4:]
        with sealed_tree_snapshot(source, profile) as snapshot:
            result = run_snapshot_command(command, snapshot.root)
            raise SystemExit(result.returncode)
    if len(arguments) >= 8 and arguments[0] == "promote-exec":
        profile = arguments[1]
        source = Path(arguments[2])
        destination = Path(arguments[3])
        if arguments[4] != "--mutate":
            fail("promote-exec requires one fixed mutate command")
        try:
            verify_index = arguments.index("--verify", 5)
        except ValueError:
            fail("promote-exec requires one fixed final verification command")
        mutate_command = arguments[5:verify_index]
        verify_command = arguments[verify_index + 1 :]
        promote_mutated_snapshot(
            profile,
            source,
            destination,
            mutate_command,
            verify_command,
        )
        return
    if len(arguments) == 5 and arguments[0] == "copy-file":
        source = Path(arguments[1])
        destination = Path(arguments[2])
        digest = arguments[3]
        try:
            maximum = int(arguments[4])
        except ValueError:
            fail("verified file maximum size is invalid")
        print(copy_verified_file(source, destination, digest, maximum))
        return
    if len(arguments) == 4 and arguments[0] == "verify-file":
        path = Path(arguments[1])
        digest = arguments[2]
        try:
            maximum = int(arguments[3])
        except ValueError:
            fail("verified file maximum size is invalid")
        actual = stable_file_sha256(path, maximum)
        if actual != digest:
            fail("verified file digest no longer matches")
        print(actual)
        return
    if len(arguments) == 6 and arguments[0] == "promote-delivery":
        source = Path(arguments[1])
        destination = Path(arguments[2])
        try:
            maximum = int(arguments[5])
        except ValueError:
            fail("delivery maximum IPA size is invalid")
        promote_verified_delivery(
            source,
            destination,
            arguments[3],
            arguments[4],
            maximum,
        )
        return
    fail(
        "usage: app2_filesystem_snapshot.py "
        "exec archive|app <source> -- <command...> | "
        "promote-exec archive|app <source> <new-destination> "
        "--mutate <command...> --verify <command...> | "
        "copy-file <source> <new-destination> <sha256> <max-bytes> | "
        "verify-file <path> <sha256> <max-bytes> | "
        "promote-delivery <source-dir> <new-destination> "
        "<ipa-sha256> <evidence-sha256> <max-ipa-bytes>"
    )


if __name__ == "__main__":
    command_main(sys.argv[1:])
