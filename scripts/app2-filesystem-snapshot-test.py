#!/usr/bin/env python3
"""Regression tests for stable APP2 filesystem snapshots."""

from __future__ import annotations

import os
import subprocess
import sys
import tempfile
import threading
from pathlib import Path


SCRIPT_DIR = Path(__file__).resolve().parent
def fail(message: str) -> None:
    raise SystemExit(f"APP2 filesystem snapshot test failed: {message}")


def expect_blocked(action: object, message: str) -> None:
    try:
        action()
    except SystemExit:
        return
    fail(message)


def main() -> None:
    import app2_filesystem_snapshot as module

    def snapshot_once(path: Path, profile: str) -> None:
        with module.sealed_tree_snapshot(path, profile):
            pass

    with tempfile.TemporaryDirectory(
        prefix="wenxintong-app2-snapshot-test."
    ) as directory:
        root = Path(directory)
        source = root / "source.app"
        source.mkdir(mode=0o755)
        executable = source / "WenxintongApp2"
        executable.write_bytes(b"stable-executable")
        executable.chmod(0o755)
        (source / "Resources").mkdir()
        (source / "Resources" / "asset").write_bytes(b"stable-asset")
        with module.sealed_tree_snapshot(source, "app") as snapshot:
            if (snapshot.root / "WenxintongApp2").read_bytes() != b"stable-executable":
                fail("snapshot content differs from source")
            if (snapshot.root / "WenxintongApp2").stat().st_mode & 0o777 != 0o755:
                fail("snapshot did not preserve the approved file mode")

        linked = root / "linked.app"
        linked.mkdir()
        (linked / "target").write_bytes(b"target")
        (linked / "link").symlink_to("target")
        expect_blocked(
            lambda: snapshot_once(linked, "app"),
            "app symbolic link unexpectedly passed",
        )

        racing = root / "racing.xcarchive"
        racing.mkdir()
        large = racing / "A-large.bin"
        large.write_bytes(b"x" * (8 * 1024 * 1024))
        (racing / "Info.plist").write_bytes(b"metadata")
        started = threading.Event()
        injected = threading.Event()
        original_read = module.os.read

        def observed_read(descriptor: int, size: int) -> bytes:
            chunk = original_read(descriptor, size)
            try:
                state = os.fstat(descriptor)
            except OSError:
                return chunk
            if state.st_size == large.stat().st_size and chunk and not started.is_set():
                started.set()
                injected.wait(timeout=5)
            return chunk

        def inject_entry() -> None:
            if not started.wait(timeout=5):
                return
            (racing / "ZZ-injected.bin").write_bytes(b"injected-after-enumeration")
            injected.set()

        worker = threading.Thread(target=inject_entry)
        worker.start()
        module.os.read = observed_read
        try:
            expect_blocked(
                lambda: snapshot_once(racing, "archive"),
                "directory entry injection during snapshot unexpectedly passed",
            )
        finally:
            module.os.read = original_read
            injected.set()
            worker.join()
        if not (racing / "ZZ-injected.bin").exists():
            fail("directory injection test did not execute")

        promotion_source = root / "promotion-source.xcarchive"
        promotion_source.mkdir()
        (promotion_source / "payload").write_bytes(b"before")
        promotion_target = root / "promotion-target.xcarchive"
        working_roots: list[Path] = []
        original_run_snapshot_command = module.run_snapshot_command

        def mutate_working_after_verify(
            command: list[str],
            snapshot_root: Path,
        ) -> subprocess.CompletedProcess[bytes]:
            result = original_run_snapshot_command(command, snapshot_root)
            if not working_roots:
                working_roots.append(snapshot_root)
            elif len(working_roots) == 1:
                (working_roots[0] / "payload").write_bytes(b"late-working-mutation")
                working_roots.append(snapshot_root)
            return result

        module.run_snapshot_command = mutate_working_after_verify
        try:
            module.promote_mutated_snapshot(
                "archive",
                promotion_source,
                promotion_target,
                [
                    sys.executable,
                    "-c",
                    "from pathlib import Path; "
                    "Path(__import__('sys').argv[1], 'payload').write_bytes(b'mutated')",
                    "{snapshot}",
                ],
                [
                    sys.executable,
                    "-c",
                    "from pathlib import Path; import sys; "
                    "assert Path(sys.argv[1], 'payload').read_bytes() == b'mutated'",
                    "{snapshot}",
                ],
            )
        finally:
            module.run_snapshot_command = original_run_snapshot_command
        if (promotion_target / "payload").read_bytes() != b"mutated":
            fail("post-verification working mutation reached the promoted target")

        mutated_final_source = root / "mutated-final-source.xcarchive"
        mutated_final_source.mkdir()
        (mutated_final_source / "payload").write_bytes(b"stable")
        mutated_final_target = root / "mutated-final-target.xcarchive"
        expect_blocked(
            lambda: module.promote_mutated_snapshot(
                "archive",
                mutated_final_source,
                mutated_final_target,
                ["/usr/bin/true"],
                [
                    sys.executable,
                    "-c",
                    "from pathlib import Path; import sys; "
                    "Path(sys.argv[1], 'payload').write_bytes(b'changed-by-verifier')",
                    "{snapshot}",
                ],
            ),
            "a verifier mutation of the final snapshot unexpectedly promoted",
        )
        if mutated_final_target.exists():
            fail("failed final-snapshot verification left a promoted target")

        late_source = root / "late-source"
        late_source.mkdir()
        (late_source / "payload").write_bytes(b"approved")
        late_target = root / "late-target"
        late_digest = module._snapshot_content_digest(late_source, "archive")
        original_exchange = module._renameat_exchange
        late_mutation_injected = False

        def mutate_after_digest_before_rename(
            source_parent_fd: int,
            source_name: str,
            destination_parent_fd: int,
            destination_name: str,
        ) -> None:
            nonlocal late_mutation_injected
            if source_name == late_source.name and not late_mutation_injected:
                source_fd = os.open(
                    source_name,
                    os.O_RDONLY | getattr(os, "O_DIRECTORY", 0),
                    dir_fd=source_parent_fd,
                )
                try:
                    payload_fd = os.open(
                        "payload",
                        os.O_WRONLY | getattr(os, "O_NOFOLLOW", 0),
                        dir_fd=source_fd,
                    )
                    try:
                        os.ftruncate(payload_fd, 0)
                        os.write(payload_fd, b"late-digest-race")
                    finally:
                        os.close(payload_fd)
                finally:
                    os.close(source_fd)
                late_mutation_injected = True
            original_exchange(
                source_parent_fd,
                source_name,
                destination_parent_fd,
                destination_name,
            )

        module._renameat_exchange = mutate_after_digest_before_rename
        try:
            expect_blocked(
                lambda: module._promote_directory_transaction(
                    late_source,
                    late_target,
                    profile="archive",
                    expected_digest=late_digest,
                ),
                "a digest-to-rename late mutation unexpectedly promoted",
            )
        finally:
            module._renameat_exchange = original_exchange
        if late_target.exists() or not late_mutation_injected:
            fail("late digest mutation test left a formal target or did not run")
        if list(root.glob(".wenxintong-app2-quarantine.*")):
            fail("late digest mutation left a quarantine directory")

        source_parent = root / "source-parent"
        destination_parent = root / "destination-parent"
        replaced_parent = root / "destination-parent-original"
        source_parent.mkdir()
        destination_parent.mkdir()
        swap_source = source_parent / "sealed"
        swap_source.mkdir()
        (swap_source / "payload").write_bytes(b"stable")
        genuine_source = source_parent / "genuine-held-away"
        swap_target = destination_parent / "promoted"
        parent_swapped = False
        source_name_occupied = False

        def swap_destination_parent_then_rename(
            source_parent_fd: int,
            source_name: str,
            destination_parent_fd: int,
            destination_name: str,
        ) -> None:
            nonlocal parent_swapped, source_name_occupied
            if not parent_swapped:
                os.rename(destination_parent, replaced_parent)
                destination_parent.mkdir()
                parent_swapped = True
            if not source_name_occupied:
                os.rename(swap_source, genuine_source)
                occupied = swap_source
                occupied.mkdir()
                (occupied / "owner").write_bytes(b"concurrent-owner")
                source_name_occupied = True
            original_exchange(
                source_parent_fd,
                source_name,
                destination_parent_fd,
                destination_name,
            )

        module._renameat_exchange = swap_destination_parent_then_rename
        try:
            swap_digest = module._snapshot_content_digest(swap_source, "archive")
            expect_blocked(
                lambda: module._promote_directory_transaction(
                    swap_source,
                    swap_target,
                    profile="archive",
                    expected_digest=swap_digest,
                ),
                "parent replacement and source-name occupation unexpectedly passed",
            )
        finally:
            module._renameat_exchange = original_exchange
        if (destination_parent / "promoted").exists():
            fail("parent replacement received the promoted directory")
        if (replaced_parent / "promoted").exists():
            fail("held original parent retained the failed formal target")
        if (swap_source / "owner").read_bytes() != b"concurrent-owner":
            fail("rollback touched the concurrent source-name owner")
        if (genuine_source / "payload").read_bytes() != b"stable":
            fail("source replacement test lost the held genuine directory")
        if (
            list(destination_parent.glob(".wenxintong-app2-quarantine.*"))
            or list(replaced_parent.glob(".wenxintong-app2-quarantine.*"))
        ):
            fail("parent-swap rollback left a quarantine directory")

        delivery_source = root / "delivery-source"
        delivery_source.mkdir()
        delivery_ipa = delivery_source / "WenxintongApp2.ipa"
        delivery_evidence = delivery_source / "APP2_IPA_VERIFICATION.json"
        delivery_ipa.write_bytes(b"verified-ipa")
        delivery_evidence.write_bytes(b'{"verified":true}\n')
        delivery_target = root / "delivery-target"
        original_delivery_evidence = module._verified_delivery_evidence
        delivery_validation_count = 0

        def fail_final_delivery_validation(
            directory_fd: int,
            ipa_sha256: str,
            evidence_sha256: str,
            maximum_ipa_bytes: int,
        ) -> object:
            nonlocal delivery_validation_count
            delivery_validation_count += 1
            result = original_delivery_evidence(
                directory_fd,
                ipa_sha256,
                evidence_sha256,
                maximum_ipa_bytes,
            )
            if delivery_validation_count == 3:
                raise SystemExit("injected post-promotion delivery failure")
            return result

        module._verified_delivery_evidence = fail_final_delivery_validation
        try:
            expect_blocked(
                lambda: module.promote_verified_delivery(
                    delivery_source,
                    delivery_target,
                    module.stable_file_sha256(delivery_ipa, 1024),
                    module.stable_file_sha256(delivery_evidence, 1024),
                    1024,
                ),
                "post-promotion delivery validation unexpectedly passed",
            )
        finally:
            module._verified_delivery_evidence = original_delivery_evidence
        if delivery_target.exists() or delivery_validation_count != 3:
            fail("failed delivery validation left a formal target")
        if list(root.glob(".wenxintong-app2-quarantine.*")):
            fail("failed delivery validation left a quarantine directory")

        fd_source = root / "fd-bound-source"
        fd_source.mkdir()
        (fd_source / "payload").write_bytes(b"held-root-content")
        fd_destination_parent = root / "fd-destination-parent"
        fd_destination_parent.mkdir()
        parked_destination_parent = root / "fd-destination-parent-held"
        fd_target = fd_destination_parent / "formal-target"
        validator_calls = 0
        observed_root_inode: tuple[int, int] | None = None
        observed_decoy_inode: tuple[int, int] | None = None

        def fd_bound_validator(root_fd: int) -> object:
            nonlocal validator_calls, observed_root_inode, observed_decoy_inode
            validator_calls += 1
            held = os.fstat(root_fd)
            payload_fd = os.open(
                "payload",
                os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0),
                dir_fd=root_fd,
            )
            try:
                payload = os.read(payload_fd, 1024)
            finally:
                os.close(payload_fd)
            if validator_calls == 2:
                os.rename(
                    fd_destination_parent,
                    parked_destination_parent,
                )
                fd_destination_parent.mkdir()
                decoy = fd_destination_parent / fd_target.name
                decoy.mkdir()
                (decoy / "payload").write_bytes(b"decoy-content")
                decoy_state = os.stat(decoy)
                observed_decoy_inode = (decoy_state.st_dev, decoy_state.st_ino)
                try:
                    second_payload_fd = os.open(
                        "payload",
                        os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0),
                        dir_fd=root_fd,
                    )
                    try:
                        if os.read(second_payload_fd, 1024) != b"held-root-content":
                            fail("fd-bound validator observed the temporary decoy")
                    finally:
                        os.close(second_payload_fd)
                finally:
                    (decoy / "payload").unlink()
                    decoy.rmdir()
                    fd_destination_parent.rmdir()
                    os.rename(
                        parked_destination_parent,
                        fd_destination_parent,
                    )
            observed_root_inode = (held.st_dev, held.st_ino)
            return observed_root_inode, payload

        module._promote_directory_transaction(
            fd_source,
            fd_target,
            validator=fd_bound_validator,
        )
        formal_state = os.stat(fd_target)
        formal_inode = (formal_state.st_dev, formal_state.st_ino)
        if (
            validator_calls != 3
            or observed_root_inode != formal_inode
            or observed_decoy_inode == formal_inode
            or (fd_target / "payload").read_bytes() != b"held-root-content"
        ):
            fail("validator was not bound to the promoted formal-target inode")
        if list(fd_destination_parent.glob(".wenxintong-app2-quarantine.*")):
            fail("successful fd-bound promotion left a quarantine directory")

        unknown_parent = root / "unknown-formal-parent"
        unknown_parent.mkdir()
        unknown_formal = unknown_parent / "formal"
        unknown_formal.mkdir()
        (unknown_formal / "payload").write_bytes(b"expected-genuine")
        genuine_away = unknown_parent / "genuine-away"
        unknown_quarantine = unknown_parent / "private-quarantine"
        unknown_quarantine.mkdir(mode=0o700)
        unknown_parent_fd = os.open(
            unknown_parent,
            os.O_RDONLY | getattr(os, "O_DIRECTORY", 0),
        )
        unknown_quarantine_fd = os.open(
            unknown_quarantine,
            os.O_RDONLY | getattr(os, "O_DIRECTORY", 0),
        )
        expected_formal_state = os.stat(unknown_formal)
        original_exchange = module._renameat_exchange
        unknown_replacement_injected = False

        def replace_formal_before_retract_exchange(
            left_parent_fd: int,
            left_name: str,
            right_parent_fd: int,
            right_name: str,
        ) -> None:
            nonlocal unknown_replacement_injected
            if not unknown_replacement_injected:
                os.rename(unknown_formal, genuine_away)
                unknown_formal.mkdir()
                (unknown_formal / "owner").write_bytes(b"caller-owned")
                unknown_replacement_injected = True
            original_exchange(
                left_parent_fd,
                left_name,
                right_parent_fd,
                right_name,
            )

        module._renameat_exchange = replace_formal_before_retract_exchange
        try:
            try:
                module._retract_failed_promotion(
                    unknown_parent_fd,
                    unknown_formal.name,
                    unknown_quarantine_fd,
                    expected_formal_state,
                )
            except RuntimeError:
                pass
            else:
                fail("unknown formal replacement unexpectedly retracted")
        finally:
            module._renameat_exchange = original_exchange
            os.close(unknown_quarantine_fd)
            os.close(unknown_parent_fd)
        if (
            not unknown_replacement_injected
            or (unknown_formal / "owner").read_bytes() != b"caller-owned"
            or (genuine_away / "payload").read_bytes() != b"expected-genuine"
            or any(unknown_quarantine.iterdir())
        ):
            fail("unknown formal retract moved or deleted a caller-owned inode")

        cleanup_parent = root / "cleanup-parent"
        cleanup_parent.mkdir()
        cleanup_parent_fd = os.open(
            cleanup_parent,
            os.O_RDONLY | getattr(os, "O_DIRECTORY", 0),
        )
        quarantine_name, quarantine_fd = module._reserve_private_quarantine(
            cleanup_parent_fd
        )
        parked_quarantine = quarantine_name + ".held"
        replacement = cleanup_parent / quarantine_name / "owner"
        try:
            os.rename(
                quarantine_name,
                parked_quarantine,
                src_dir_fd=cleanup_parent_fd,
                dst_dir_fd=cleanup_parent_fd,
            )
            os.mkdir(quarantine_name, 0o700, dir_fd=cleanup_parent_fd)
            replacement.write_bytes(b"caller-owned")
            try:
                module._remove_reserved_quarantine(
                    cleanup_parent_fd,
                    quarantine_name,
                    quarantine_fd,
                )
            except RuntimeError:
                pass
            else:
                fail("replaced quarantine name was mistakenly removed")
            if replacement.read_bytes() != b"caller-owned":
                fail("quarantine cleanup touched a caller replacement directory")
        finally:
            os.close(quarantine_fd)
            replacement.unlink()
            (cleanup_parent / quarantine_name).rmdir()
            (cleanup_parent / parked_quarantine).rmdir()
            os.close(cleanup_parent_fd)

    print(
        "PASS: APP2 promotion binds validators to one inode, restores source/"
        "formal replacements, and retracts late mutation safely."
    )


if __name__ == "__main__":
    main()
