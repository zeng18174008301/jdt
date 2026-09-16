#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/wenxintong-app2-ipa-test.XXXXXX")"
trap 'rm -rf "$temp_dir"' EXIT

fail() {
  printf 'APP2 IPA safe extraction test failed: %s\n' "$1" >&2
  exit 1
}

python3 - "$temp_dir" <<'PY'
import stat
import sys
import unicodedata
import zipfile
from pathlib import Path

root = Path(sys.argv[1])

with zipfile.ZipFile(root / "valid.ipa", "w", compression=zipfile.ZIP_DEFLATED) as archive:
    archive.writestr("Payload/WenxintongApp2.app/Info.plist", b"plist")
    executable = zipfile.ZipInfo("Payload/WenxintongApp2.app/WenxintongApp2")
    executable.external_attr = (stat.S_IFREG | 0o755) << 16
    archive.writestr(executable, b"binary")

with zipfile.ZipFile(root / "traversal.ipa", "w") as archive:
    archive.writestr("Payload/WenxintongApp2.app/Info.plist", b"plist")
    archive.writestr("../escaped", b"blocked")

with zipfile.ZipFile(root / "control-path.ipa", "w") as archive:
    archive.writestr("Payload/WenxintongApp2.app/Info.plist", b"plist")
    archive.writestr("Payload/WenxintongApp2.app/line\nbreak", b"blocked")

with zipfile.ZipFile(root / "symlink.ipa", "w") as archive:
    archive.writestr("Payload/WenxintongApp2.app/Info.plist", b"plist")
    link = zipfile.ZipInfo("Payload/WenxintongApp2.app/link")
    link.external_attr = (stat.S_IFLNK | 0o777) << 16
    archive.writestr(link, b"/etc/passwd")

with zipfile.ZipFile(root / "case-collision.ipa", "w") as archive:
    archive.writestr("Payload/WenxintongApp2.app/Info.plist", b"plist")
    archive.writestr("payload/wenxintongapp2.app/info.plist", b"collision")

with zipfile.ZipFile(root / "unicode-collision.ipa", "w") as archive:
    archive.writestr("Payload/WenxintongApp2.app/Info.plist", b"plist")
    archive.writestr(
        "Payload/WenxintongApp2.app/" + unicodedata.normalize("NFC", "cafe\u0301"),
        b"nfc",
    )
    archive.writestr(
        "Payload/WenxintongApp2.app/" + unicodedata.normalize("NFD", "caf\u00e9"),
        b"nfd",
    )

with zipfile.ZipFile(root / "unicode-prefix-collision.ipa", "w") as archive:
    archive.writestr("Payload/WenxintongApp2.app/Info.plist", b"plist")
    archive.writestr(
        "Payload/WenxintongApp2.app/"
        + unicodedata.normalize("NFC", "cafe\u0301")
        + "/first",
        b"nfc",
    )
    archive.writestr(
        "Payload/WenxintongApp2.app/"
        + unicodedata.normalize("NFD", "caf\u00e9")
        + "/second",
        b"nfd",
    )

with zipfile.ZipFile(root / "file-directory-conflict.ipa", "w") as archive:
    archive.writestr("Payload/WenxintongApp2.app/Info.plist", b"plist")
    archive.writestr("Payload/WenxintongApp2.app/conflict", b"file")
    archive.writestr("Payload/WenxintongApp2.app/conflict/child", b"child")

with zipfile.ZipFile(root / "special.ipa", "w") as archive:
    archive.writestr("Payload/WenxintongApp2.app/Info.plist", b"plist")
    special = zipfile.ZipInfo("Payload/WenxintongApp2.app/device")
    special.external_attr = (stat.S_IFCHR | 0o600) << 16
    archive.writestr(special, b"blocked")

with zipfile.ZipFile(root / "two-apps.ipa", "w") as archive:
    archive.writestr("Payload/WenxintongApp2.app/Info.plist", b"plist")
    archive.writestr("Payload/Other.app/Info.plist", b"plist")

with zipfile.ZipFile(root / "ratio-bomb.ipa", "w", compression=zipfile.ZIP_DEFLATED) as archive:
    archive.writestr("Payload/WenxintongApp2.app/Info.plist", b"plist")
    archive.writestr(
        "Payload/WenxintongApp2.app/compressible.bin",
        b"\0" * (9 * 1024 * 1024),
    )

crc_path = root / "crc.ipa"
with zipfile.ZipFile(crc_path, "w", compression=zipfile.ZIP_STORED) as archive:
    archive.writestr("Payload/WenxintongApp2.app/Info.plist", b"plist")
    archive.writestr("Payload/WenxintongApp2.app/crc.bin", b"crc-target-content")
corrupted = bytearray(crc_path.read_bytes())
offset = corrupted.find(b"crc-target-content")
assert offset >= 0
corrupted[offset] ^= 0x01
crc_path.write_bytes(corrupted)
PY

python3 "$script_dir/app2-ipa-safe-extract.py" \
  "$temp_dir/valid.ipa" \
  "$temp_dir/valid-output" \
  "$temp_dir/valid-sealed.ipa" >"$temp_dir/evidence.json"
if ! python3 - "$temp_dir/evidence.json" "$temp_dir/valid-sealed.ipa" <<'PY'
import hashlib
import json
import sys
import zipfile
from pathlib import Path

evidence = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
sealed = Path(sys.argv[2])
assert evidence["schema_version"] == 1
assert evidence["app_bundle_relative_path"] == "Payload/WenxintongApp2.app"
assert len(evidence["ipa_sha256"]) == 64
assert len(evidence["app_payload_sha256"]) == 64
assert evidence["ipa_sha256"] == hashlib.sha256(sealed.read_bytes()).hexdigest()
assert zipfile.is_zipfile(sealed)
PY
then
  fail "valid IPA evidence is invalid"
fi

for blocked in \
  traversal \
  control-path \
  symlink \
  case-collision \
  unicode-collision \
  unicode-prefix-collision \
  file-directory-conflict \
  special \
  two-apps \
  ratio-bomb \
  crc; do
  if python3 "$script_dir/app2-ipa-safe-extract.py" \
    "$temp_dir/$blocked.ipa" \
    "$temp_dir/$blocked-output" \
    "$temp_dir/$blocked-sealed.ipa" >"$temp_dir/$blocked.out" 2>&1; then
    fail "$blocked IPA unexpectedly passed"
  fi
  [[ ! -e "$temp_dir/$blocked-output" &&
     ! -e "$temp_dir/$blocked-sealed.ipa" ]] ||
    fail "$blocked IPA left a partial extraction or sealed artifact"
done

[[ ! -e "$temp_dir/escaped" ]] ||
  fail "path traversal wrote outside the extraction root"

printf 'concurrent-owner\n' >"$temp_dir/occupied-sealed.ipa"
if python3 "$script_dir/app2-ipa-safe-extract.py" \
  "$temp_dir/valid.ipa" \
  "$temp_dir/occupied-output" \
  "$temp_dir/occupied-sealed.ipa" >"$temp_dir/occupied.log" 2>&1; then
  fail "pre-existing sealed artifact unexpectedly passed"
fi
[[ "$(cat "$temp_dir/occupied-sealed.ipa")" == "concurrent-owner" &&
   ! -e "$temp_dir/occupied-output" ]] ||
  fail "failed extraction altered a concurrently owned sealed artifact"

python3 - "$script_dir/app2-ipa-safe-extract.py" "$temp_dir" <<'PY'
import hashlib
import json
import os
import subprocess
import sys
import threading
import time
import zipfile
from pathlib import Path

extractor = Path(sys.argv[1])
root = Path(sys.argv[2])
source = root / "race-source.ipa"
replacement = root / "race-replacement"
replacement.write_bytes(b"not-a-zip")
with zipfile.ZipFile(source, "w", compression=zipfile.ZIP_STORED) as archive:
    archive.writestr("Payload/WenxintongApp2.app/Info.plist", b"plist")
    archive.writestr(
        "Payload/WenxintongApp2.app/padding.bin",
        b"x" * (32 * 1024 * 1024),
    )
output = root / "race-output"
sealed = root / "race-sealed.ipa"
swapped = []

def swap_source() -> None:
    deadline = time.time() + 10
    while time.time() < deadline:
        if sealed.exists() and sealed.stat().st_size > 1024 * 1024:
            os.replace(replacement, source)
            swapped.append(True)
            return
        time.sleep(0.0005)

worker = threading.Thread(target=swap_source)
worker.start()
result = subprocess.run(
    ["python3", str(extractor), str(source), str(output), str(sealed)],
    capture_output=True,
    text=True,
)
worker.join()
assert swapped, "source replacement race did not execute"
assert result.returncode != 0, "replaced source pathname unexpectedly passed"
assert not zipfile.is_zipfile(source)
assert not output.exists()
assert not sealed.exists()
PY

python3 - "$script_dir/app2-ipa-safe-extract.py" "$temp_dir" <<'PY'
import os
import subprocess
import sys
import threading
import time
import zipfile
from pathlib import Path

extractor = Path(sys.argv[1])
root = Path(sys.argv[2])
source = root / "sealed-path-race-source.ipa"
with zipfile.ZipFile(source, "w", compression=zipfile.ZIP_STORED) as archive:
    archive.writestr("Payload/WenxintongApp2.app/Info.plist", b"plist")
    archive.writestr(
        "Payload/WenxintongApp2.app/padding.bin",
        b"x" * (32 * 1024 * 1024),
    )
output = root / "sealed-path-race-output"
sealed = root / "sealed-path-race.ipa"
swapped = []

def swap_sealed_path() -> None:
    deadline = time.time() + 10
    while time.time() < deadline:
        if sealed.exists() and sealed.stat().st_size > 1024 * 1024:
            replacement = root / "sealed-path-race-replacement"
            replacement.write_bytes(b"unverified-replacement")
            os.replace(replacement, sealed)
            swapped.append(True)
            return
        time.sleep(0.0005)

worker = threading.Thread(target=swap_sealed_path)
worker.start()
result = subprocess.run(
    ["python3", str(extractor), str(source), str(output), str(sealed)],
    capture_output=True,
    text=True,
)
worker.join()
assert swapped, "sealed path replacement race did not execute"
assert result.returncode != 0, "replaced sealed path unexpectedly passed"
assert not output.exists()
assert not sealed.exists()
PY

printf 'PASS: APP2 IPA extractor seals one inode and rejects traversal, Unicode/case collisions, links, special files, CRC faults, bombs and multiple apps.\n'
