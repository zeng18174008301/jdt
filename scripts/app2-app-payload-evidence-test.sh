#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/wenxintong-app2-payload-test.XXXXXX")"
trap 'rm -rf "$temp_dir"' EXIT

fail() {
  printf 'APP2 payload evidence test failed: %s\n' "$1" >&2
  exit 1
}

mkdir -p "$temp_dir/bin"
cat >"$temp_dir/bin/codesign" <<'SH'
#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" == "--verify" ]]; then
  exit 0
fi
if [[ "${1:-}" == "--remove-signature" ]]; then
  python3 - "${2:-}" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
marker = b"\n--CODE-SIGNATURE--\n"
body, separator, _ = path.read_bytes().partition(marker)
if not separator:
    raise SystemExit(1)
path.write_bytes(body)
PY
  exit 0
fi
if [[ "${1:-}" == "-d" && "${2:-}" == "--entitlements" ]]; then
  bundle="${4:-}"
  python3 - "$bundle" "${FAKE_EXPORT_ENTITLEMENT_DRIFT:-NO}" <<'PY'
import plistlib
import sys
from pathlib import Path

bundle = sys.argv[1]
bundle_path = Path(bundle)
executables = [
    bundle_path / "WenxintongApp2",
    bundle_path / "Share",
]
drift = (
    sys.argv[2] == "YES"
    and any(
        candidate.is_file()
        and b"export-signature" in candidate.read_bytes()
        for candidate in executables
    )
)
value = {
    "application-identifier": (
        "TEAM.com.wenxintong.app2.drift"
        if drift
        else "TEAM.com.wenxintong.app2"
    ),
    "com.apple.developer.team-identifier": "TEAM",
}
sys.stdout.buffer.write(plistlib.dumps(value, fmt=plistlib.FMT_XML, sort_keys=True))
PY
  exit 0
fi
if [[ "${1:-}" == "-d" && "${2:-}" == "--extract-certificates" ]]; then
  printf 'same-leaf-certificate' >"${3:-}0"
  exit 0
fi
exit 2
SH
cat >"$temp_dir/bin/security" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
[[ "${1:-}" == "cms" && "${2:-}" == "-D" && "${3:-}" == "-i" ]] || exit 2
cat "${4:-}"
SH
chmod 700 "$temp_dir/bin/codesign" "$temp_dir/bin/security"

python3 - "$temp_dir" <<'PY'
import plistlib
import sys
from pathlib import Path

root = Path(sys.argv[1])
marker = b"\n--CODE-SIGNATURE--\n"
profile = {
    "UUID": "11111111-2222-3333-4444-555555555555",
    "TeamIdentifier": ["TEAM"],
    "Entitlements": {
        "application-identifier": "TEAM.com.wenxintong.app2",
        "com.apple.developer.team-identifier": "TEAM",
    },
}
for name, signature in (("archive.app", b"archive-signature"), ("export.app", b"export-signature")):
    app = root / name
    extension = app / "PlugIns" / "Share.appex"
    (app / "_CodeSignature").mkdir(parents=True)
    (extension / "_CodeSignature").mkdir(parents=True)
    (app / "Assets").mkdir()
    (app / "Info.plist").write_bytes(
        plistlib.dumps(
            {
                "CFBundleExecutable": "WenxintongApp2",
                "CFBundleIdentifier": "com.wenxintong.app2",
            },
            fmt=plistlib.FMT_BINARY,
            sort_keys=True,
        )
    )
    (extension / "Info.plist").write_bytes(
        plistlib.dumps(
            {
                "CFBundleExecutable": "Share",
                "CFBundleIdentifier": "com.wenxintong.app2.share",
            },
            fmt=plistlib.FMT_BINARY,
            sort_keys=True,
        )
    )
    (app / "embedded.mobileprovision").write_bytes(
        plistlib.dumps(profile, fmt=plistlib.FMT_XML, sort_keys=True)
    )
    (extension / "embedded.mobileprovision").write_bytes(
        plistlib.dumps(profile, fmt=plistlib.FMT_XML, sort_keys=True)
    )
    (app / "WenxintongApp2").write_bytes(
        b"ROOT-MACHO-BODY" + marker + signature
    )
    (extension / "Share").write_bytes(
        b"NESTED-MACHO-BODY" + marker + signature
    )
    (app / "WenxintongApp2").chmod(0o755)
    (extension / "Share").chmod(0o755)
    (app / "_CodeSignature" / "CodeResources").write_bytes(signature)
    (extension / "_CodeSignature" / "CodeResources").write_bytes(signature)
    (app / "Assets" / "payload.dat").write_bytes(b"same-stable-payload")
PY

run_compare() {
  PATH="$temp_dir/bin:$PATH" \
    python3 "$script_dir/app2-app-payload-evidence.py" \
      "$temp_dir/archive.app" \
      "$temp_dir/export.app"
}

run_compare >"$temp_dir/baseline.json" ||
  fail "signature-only executable differences did not pass"
python3 - "$temp_dir/baseline.json" <<'PY'
import json
import sys
from pathlib import Path

value = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
assert value["schema_version"] == 1
assert len(value["signed_bundles"]) == 2
assert value["root_mode"] == 0o755
assert value["directory_modes"]["Assets"] == 0o755
for bundle in value["signed_bundles"]:
    assert bundle["archive_executable_sha256"] != bundle["export_executable_sha256"]
    assert len(bundle["unsigned_executable_sha256"]) == 64
PY

chmod 700 "$temp_dir/export.app"
if run_compare >"$temp_dir/root-mode.log" 2>&1; then
  fail "changed app root mode unexpectedly passed"
fi
chmod 755 "$temp_dir/export.app"

chmod 700 "$temp_dir/export.app/Assets"
if run_compare >"$temp_dir/directory-mode.log" 2>&1; then
  fail "changed recursive directory mode unexpectedly passed"
fi
chmod 755 "$temp_dir/export.app/Assets"

chmod 744 "$temp_dir/export.app/WenxintongApp2"
if run_compare >"$temp_dir/executable-mode.log" 2>&1; then
  fail "changed signing-mutable executable mode unexpectedly passed"
fi
chmod 755 "$temp_dir/export.app/WenxintongApp2"

chmod 600 "$temp_dir/export.app/embedded.mobileprovision"
if run_compare >"$temp_dir/profile-mode.log" 2>&1; then
  fail "changed signing-mutable profile mode unexpectedly passed"
fi
chmod 644 "$temp_dir/export.app/embedded.mobileprovision"

chmod 600 "$temp_dir/export.app/_CodeSignature/CodeResources"
if run_compare >"$temp_dir/code-resources-mode.log" 2>&1; then
  fail "changed CodeResources mode unexpectedly passed"
fi
chmod 644 "$temp_dir/export.app/_CodeSignature/CodeResources"

cp "$temp_dir/export.app/WenxintongApp2" "$temp_dir/root-executable.before"
python3 - "$temp_dir/export.app/WenxintongApp2" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
path.write_bytes(path.read_bytes().replace(b"ROOT-MACHO-BODY", b"EVIL-MACHO-BODY"))
PY
if run_compare >"$temp_dir/root-drift.log" 2>&1; then
  fail "changed root executable body unexpectedly passed"
fi
cp "$temp_dir/root-executable.before" "$temp_dir/export.app/WenxintongApp2"

cp "$temp_dir/export.app/PlugIns/Share.appex/Share" "$temp_dir/nested-executable.before"
python3 - "$temp_dir/export.app/PlugIns/Share.appex/Share" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
path.write_bytes(path.read_bytes().replace(b"NESTED-MACHO-BODY", b"CHANGED-MACHO-BODY"))
PY
if run_compare >"$temp_dir/nested-drift.log" 2>&1; then
  fail "changed nested executable body unexpectedly passed"
fi
cp "$temp_dir/nested-executable.before" "$temp_dir/export.app/PlugIns/Share.appex/Share"

printf 'changed-stable-payload' >"$temp_dir/export.app/Assets/payload.dat"
if run_compare >"$temp_dir/stable-drift.log" 2>&1; then
  fail "changed stable resource unexpectedly passed"
fi
printf 'same-stable-payload' >"$temp_dir/export.app/Assets/payload.dat"

if FAKE_EXPORT_ENTITLEMENT_DRIFT=YES run_compare \
  >"$temp_dir/entitlement-drift.log" 2>&1; then
  fail "changed export entitlements unexpectedly passed"
fi

printf 'unexpected-archive-signature-metadata' \
  >"$temp_dir/archive.app/_CodeSignature/Unexpected"
printf 'unexpected-export-signature-metadata' \
  >"$temp_dir/export.app/_CodeSignature/Unexpected"
if run_compare >"$temp_dir/signature-metadata.log" 2>&1; then
  fail "arbitrary _CodeSignature content unexpectedly passed"
fi
rm "$temp_dir/archive.app/_CodeSignature/Unexpected"
rm "$temp_dir/export.app/_CodeSignature/Unexpected"

mkdir "$temp_dir/export.app/UnexpectedEmptyDirectory"
if run_compare >"$temp_dir/directory-set.log" 2>&1; then
  fail "a recursive directory-set mismatch unexpectedly passed"
fi
rmdir "$temp_dir/export.app/UnexpectedEmptyDirectory"

mv "$temp_dir/archive.app/_CodeSignature/CodeResources" \
  "$temp_dir/archive-CodeResources"
mv "$temp_dir/export.app/_CodeSignature/CodeResources" \
  "$temp_dir/export-CodeResources"
if run_compare >"$temp_dir/empty-signature-directory.log" 2>&1; then
  fail "empty _CodeSignature directories unexpectedly passed"
fi
mv "$temp_dir/archive-CodeResources" \
  "$temp_dir/archive.app/_CodeSignature/CodeResources"
mv "$temp_dir/export-CodeResources" \
  "$temp_dir/export.app/_CodeSignature/CodeResources"

mkdir \
  "$temp_dir/archive.app/_CodeSignature/Nested" \
  "$temp_dir/export.app/_CodeSignature/Nested"
if run_compare >"$temp_dir/nested-signature-directory.log" 2>&1; then
  fail "extra _CodeSignature directories unexpectedly passed"
fi
rmdir \
  "$temp_dir/archive.app/_CodeSignature/Nested" \
  "$temp_dir/export.app/_CodeSignature/Nested"

ln -s payload.dat "$temp_dir/export.app/Assets/linked.dat"
if run_compare >"$temp_dir/symlink.log" 2>&1; then
  fail "symbolic link in exported app unexpectedly passed"
fi

printf 'PASS: APP2 payload evidence compares complete directory/file sets and permits only one CodeResources signature slot per signed bundle.\n'
