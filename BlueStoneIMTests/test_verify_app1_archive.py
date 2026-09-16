#!/usr/bin/env python3
"""Focused fixtures for the single APP1 archive verifier authority."""

from __future__ import annotations

import datetime
import os
import plistlib
import subprocess
import tempfile
import textwrap
import unittest
from pathlib import Path


IOS_ROOT = Path(__file__).resolve().parents[1]
VERIFIER = IOS_ROOT / "scripts" / "verify_app1_archive.py"
APP2_VERIFIER = IOS_ROOT / "scripts" / "verify-app2-archive.sh"
INTERNAL_ARCHIVER = IOS_ROOT / "scripts" / "archive-internal-validation.sh"
SCHEME_ROOT = IOS_ROOT / "BlueStoneIM.xcodeproj" / "xcshareddata" / "xcschemes"


class App1ArchiveVerifierTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(prefix="app1-verifier-test-")
        self.root = Path(self.temporary.name)
        self.app_path = self.root / "BlueStoneIM.app"
        self.app_path.mkdir()
        self.team = "A3PN7W63G3"
        self.bundle = "com.wendatongqiye.app"
        self.certificate = b"synthetic-app1-distribution-certificate"
        self.entitlements_path = self.root / "entitlements.plist"
        self.profile_path = self.root / "profile.plist"
        self.certificate_path = self.root / "certificate.der"

        self.write_plist(
            self.app_path / "Info.plist",
            {
                "CFBundleIdentifier": self.bundle,
                "CFBundleExecutable": "BlueStoneIM",
                "WXTAPNsEnvironment": "production",
                "WXTAccessDiagnosticsOverlayCompiled": "YES",
            },
        )
        (self.app_path / "BlueStoneIM").write_bytes(
            b"formal-WXT_ACCESS_DIAGNOSTICS_OVERLAY_BINARY_MARKER_V1-binary"
        )
        (self.app_path / "embedded.mobileprovision").write_bytes(b"synthetic-profile")
        entitlements = {
            "application-identifier": f"{self.team}.{self.bundle}",
            "com.apple.developer.team-identifier": self.team,
            "aps-environment": "production",
            "get-task-allow": False,
        }
        self.write_plist(self.entitlements_path, entitlements)
        self.write_plist(
            self.profile_path,
            {
                "Name": "Codemagic App Store profile",
                "UUID": "00000000-0000-0000-0000-000000000001",
                "TeamIdentifier": [self.team],
                "Entitlements": entitlements,
                "ExpirationDate": datetime.datetime.now(datetime.timezone.utc)
                + datetime.timedelta(days=30),
                "DeveloperCertificates": [self.certificate],
            },
        )
        self.certificate_path.write_bytes(self.certificate)
        self.codesign_tool = self.make_executable(
            "codesign",
            """
            #!/usr/bin/env python3
            import os
            import shutil
            import sys

            arguments = sys.argv[1:]
            if arguments and arguments[0] == "--verify":
                raise SystemExit(0)
            if arguments[:2] == ["-d", "--entitlements"]:
                with open(os.environ["FAKE_APP1_ENTITLEMENTS"], "rb") as source:
                    sys.stdout.buffer.write(source.read())
                raise SystemExit(0)
            if arguments[:2] == ["-d", "--extract-certificates"]:
                shutil.copyfile(os.environ["FAKE_APP1_CERTIFICATE"], f"{arguments[2]}0")
                raise SystemExit(0)
            raise SystemExit(2)
            """,
        )
        self.security_tool = self.make_executable(
            "security",
            """
            #!/usr/bin/env python3
            import os
            import sys

            with open(os.environ["FAKE_APP1_PROFILE"], "rb") as source:
                sys.stdout.buffer.write(source.read())
            """,
        )

    def tearDown(self) -> None:
        self.temporary.cleanup()

    @staticmethod
    def write_plist(path: Path, value: dict[str, object]) -> None:
        with path.open("wb") as handle:
            plistlib.dump(value, handle)

    def make_executable(self, name: str, source: str) -> Path:
        path = self.root / name
        path.write_text(textwrap.dedent(source).lstrip(), encoding="utf-8")
        path.chmod(0o755)
        return path

    def verifier_environment(self) -> dict[str, str]:
        return {
            **os.environ,
            "APP1_VERIFY_CODESIGN_TOOL": str(self.codesign_tool),
            "APP1_VERIFY_SECURITY_TOOL": str(self.security_tool),
            "FAKE_APP1_ENTITLEMENTS": str(self.entitlements_path),
            "FAKE_APP1_PROFILE": str(self.profile_path),
            "FAKE_APP1_CERTIFICATE": str(self.certificate_path),
        }

    def run_verifier(self, mode: str | None = None) -> subprocess.CompletedProcess[str]:
        arguments = ["python3", str(VERIFIER)]
        if mode is not None:
            arguments.extend(["--mode", mode])
        arguments.append(str(self.app_path))
        return subprocess.run(
            arguments,
            capture_output=True,
            check=False,
            env=self.verifier_environment(),
            text=True,
        )

    def mark_internal_validation_build(self) -> None:
        with (self.app_path / "Info.plist").open("rb") as handle:
            info = plistlib.load(handle)
        info["WXTFormalBuild"] = "NO"
        self.write_plist(self.app_path / "Info.plist", info)

    def run_app2_candidate(
        self, *, metadata: str | None = "YES", marker: bool = True
    ) -> subprocess.CompletedProcess[str]:
        app_path = self.root / "WenxintongApp2.app"
        app_path.mkdir(exist_ok=True)
        info: dict[str, object] = {"CFBundleExecutable": "WenxintongApp2"}
        if metadata is not None:
            info["WXTAccessDiagnosticsOverlayCompiled"] = metadata
        self.write_plist(app_path / "Info.plist", info)
        executable = b"ordinary-app2-binary"
        if marker:
            executable += b"-WXT_ACCESS_DIAGNOSTICS_OVERLAY_BINARY_MARKER_V1"
        (app_path / "WenxintongApp2").write_bytes(executable)
        self.make_executable("codesign", "#!/usr/bin/env bash\nexit 0\n")
        return subprocess.run(
            ["bash", str(APP2_VERIFIER), str(app_path)],
            capture_output=True,
            check=False,
            env={
                **os.environ,
                "APP2_CANDIDATE_BUILD": "YES",
                "PATH": f"{self.root}:{os.environ['PATH']}",
            },
            text=True,
        )

    def test_valid_fixture_passes_without_secret_output(self) -> None:
        result = self.run_verifier()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("PASS: APP1 final archive verified", result.stdout)
        self.assertIn("ordinary_topic=com.wendatongqiye.app", result.stdout)
        self.assertIn("voip_topic=com.wendatongqiye.app.voip", result.stdout)
        self.assertNotIn(self.certificate.decode(), result.stdout + result.stderr)

    def test_mismatched_aps_environment_is_blocked(self) -> None:
        with self.entitlements_path.open("rb") as handle:
            entitlements = plistlib.load(handle)
        entitlements["aps-environment"] = "development"
        self.write_plist(self.entitlements_path, entitlements)

        result = self.run_verifier()
        self.assertEqual(result.returncode, 1)
        self.assertEqual(result.stdout, "")
        self.assertIn(
            "APP1 archive blocked: final archive Bundle/Team/Profile/topic identity mismatch",
            result.stderr,
        )
        self.assertNotIn(self.certificate.decode(), result.stdout + result.stderr)

    def test_formal_diagnostics_binary_marker_is_required(self) -> None:
        (self.app_path / "BlueStoneIM").write_bytes(b"formal-binary-without-marker")

        for mode in (None, "formal"):
            with self.subTest(mode=mode or "default"):
                result = self.run_verifier(mode)
                self.assertEqual(result.returncode, 1)
                self.assertEqual(result.stdout, "")
                self.assertIn("missing the diagnostics capability marker", result.stderr)

    def test_formal_diagnostics_metadata_is_required(self) -> None:
        with (self.app_path / "Info.plist").open("rb") as handle:
            info = plistlib.load(handle)
        info.pop("WXTAccessDiagnosticsOverlayCompiled")
        self.write_plist(self.app_path / "Info.plist", info)

        for mode in (None, "formal"):
            with self.subTest(mode=mode or "default"):
                result = self.run_verifier(mode)
                self.assertEqual(result.returncode, 1)
                self.assertEqual(result.stdout, "")
                self.assertIn("missing diagnostics capability metadata", result.stderr)

    def test_internal_mode_requires_and_accepts_both_diagnostics_signals(self) -> None:
        self.mark_internal_validation_build()

        result = self.run_verifier("internal-validation")

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(
            "PASS: APP1 internal-validation archive verified diagnostics=required",
            result.stdout,
        )

    def test_internal_mode_fails_closed_when_either_signal_is_missing(self) -> None:
        with (self.app_path / "Info.plist").open("rb") as handle:
            info = plistlib.load(handle)
        info["WXTFormalBuild"] = "NO"
        info.pop("WXTAccessDiagnosticsOverlayCompiled")
        self.write_plist(self.app_path / "Info.plist", info)
        missing_metadata = self.run_verifier("internal-validation")
        self.assertEqual(missing_metadata.returncode, 1)
        self.assertIn("missing diagnostics capability metadata", missing_metadata.stderr)

        info["WXTAccessDiagnosticsOverlayCompiled"] = "YES"
        self.write_plist(self.app_path / "Info.plist", info)
        (self.app_path / "BlueStoneIM").write_bytes(b"internal-binary-without-marker")
        missing_marker = self.run_verifier("internal-validation")
        self.assertEqual(missing_marker.returncode, 1)
        self.assertIn("missing the diagnostics capability marker", missing_marker.stderr)

    def test_app2_candidate_mode_requires_both_diagnostics_signals(self) -> None:
        metadata_result = self.run_app2_candidate(metadata=None, marker=True)
        self.assertEqual(metadata_result.returncode, 1)
        self.assertIn("missing diagnostics capability metadata", metadata_result.stderr)

        marker_result = self.run_app2_candidate(metadata="YES", marker=False)
        self.assertEqual(marker_result.returncode, 1)
        self.assertIn("missing the diagnostics capability marker", marker_result.stderr)

        valid_result = self.run_app2_candidate()
        self.assertEqual(valid_result.returncode, 0, valid_result.stderr)
        self.assertIn("diagnostics capability verified", valid_result.stdout)

    def test_archive_routes_select_only_their_explicit_verification_modes(self) -> None:
        self.assertTrue(VERIFIER.is_file())
        self.assertFalse((IOS_ROOT / "scripts" / "verify-app1-archive.sh").exists())
        self.assertFalse((IOS_ROOT / "scripts" / "test-verify-app1-archive.sh").exists())
        self.assertEqual(
            list((IOS_ROOT / "scripts").glob("*test*app1*")),
            [],
        )
        for scheme_name in ("BlueStoneIM-App1.xcscheme", "BlueStoneIM.xcscheme"):
            source = (SCHEME_ROOT / scheme_name).read_text(encoding="utf-8")
            self.assertIn("python3", source)
            self.assertIn("verify_app1_archive.py", source)
            self.assertIn("--mode formal", source)
            self.assertNotIn("--mode internal-validation", source)
            self.assertNotIn("verify-app1-archive.sh", source)

        internal_scheme = (
            SCHEME_ROOT / "BlueStoneIM-InternalValidation.xcscheme"
        ).read_text(encoding="utf-8")
        self.assertIn("verify_app1_archive.py", internal_scheme)
        self.assertIn("--mode internal-validation", internal_scheme)
        self.assertNotIn("--mode formal", internal_scheme)

        internal_archiver = INTERNAL_ARCHIVER.read_text(encoding="utf-8")
        self.assertIn('SCHEME="BlueStoneIM-InternalValidation"', internal_archiver)
        self.assertNotIn('SCHEME="${SCHEME:-', internal_archiver)
        self.assertNotIn("--mode formal", internal_archiver)

        app2_scheme = (SCHEME_ROOT / "BlueStoneIM-App2.xcscheme").read_text(
            encoding="utf-8"
        )
        self.assertIn("verify-app2-archive.sh", app2_scheme)
        self.assertNotIn("--mode internal-validation", app2_scheme)


if __name__ == "__main__":
    unittest.main()
