#!/usr/bin/env bash
set -euo pipefail
umask 077

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
snapshot_helper="$script_dir/app2_filesystem_snapshot.py"
max_ipa_bytes="$((1024 * 1024 * 1024))"

fail() {
  printf 'APP2 IPA verification blocked: %s\n' "$1" >&2
  exit 1
}

verify_app2_ipa_snapshot() {
local ipa_path="${1:-}"
local archive_path="${2:-}"
local delivery_directory="${3:-}"
[[ -n "$ipa_path" && "$ipa_path" == /* && -f "$ipa_path" && ! -L "$ipa_path" ]] ||
  fail "pass one absolute regular IPA path"
[[ -n "$archive_path" && "$archive_path" == /* &&
   -d "$archive_path" && ! -L "$archive_path" ]] ||
  fail "pass the verified absolute APP2 xcarchive path"
[[ -n "$delivery_directory" && "$delivery_directory" == /* &&
   ! -e "$delivery_directory" && ! -L "$delivery_directory" &&
   -d "$(dirname "$delivery_directory")" &&
   ! -L "$(dirname "$delivery_directory")" ]] ||
  fail "pass one new absolute verified delivery directory"

temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/wenxintong-app2-ipa.XXXXXX")"
verified=NO
cleanup() {
  rm -rf "$temp_dir"
}
trap cleanup EXIT
extract_dir="$temp_dir/extracted"
sealed_snapshot="$temp_dir/sealed.ipa"
private_delivery="$temp_dir/deliverable"
verified_ipa_path="$private_delivery/WenxintongApp2.ipa"
final_evidence="$private_delivery/APP2_IPA_VERIFICATION.json"
mkdir -m 700 "$private_delivery"

raw_evidence_json="$(
  python3 "$script_dir/app2-ipa-safe-extract.py" \
  "$ipa_path" \
  "$extract_dir" \
  "$sealed_snapshot"
)" || fail "safe extraction did not produce trusted in-process evidence"

app_relative="$(
  python3 - "$raw_evidence_json" <<'PY'
import json
import sys

value = json.loads(sys.argv[1])
if (
    not isinstance(value, dict)
    or value.get("schema_version") != 1
    or not isinstance(value.get("app_bundle_relative_path"), str)
):
    raise SystemExit(1)
print(value["app_bundle_relative_path"])
PY
)" || fail "safe extraction evidence is invalid"
[[ "$app_relative" == Payload/*.app && "$app_relative" != *".."* ]] ||
  fail "safe extraction returned an invalid app path"
exported_app="$extract_dir/$app_relative"
archived_app="$archive_path/Products/Applications/WenxintongApp2.app"

"$script_dir/verify-app2-release-package.sh" "$archive_path"
"$script_dir/verify-app2-archive.sh" "$exported_app"
payload_evidence_json="$(
  python3 "$script_dir/app2-app-payload-evidence.py" \
  "$archived_app" \
  "$exported_app"
)" || fail "archive and IPA payload evidence did not verify"

if ! python3 - "$archived_app/Info.plist" "$exported_app/Info.plist" <<'PY'
import plistlib
import sys
from pathlib import Path

with Path(sys.argv[1]).open("rb") as handle:
    archived = plistlib.load(handle)
with Path(sys.argv[2]).open("rb") as handle:
    exported = plistlib.load(handle)
if archived != exported:
    raise SystemExit(1)
PY
then
  fail "exported Info.plist differs from the sealed archive"
fi

evidence_sha256="$(
python3 - \
  "$raw_evidence_json" \
  "$payload_evidence_json" \
  "$archive_path/APP2_RELEASE_ATTESTATION.json" \
  "$final_evidence" <<'PY'
import hashlib
import json
import os
import stat
import sys
from pathlib import Path


def stable_file_bytes(path: Path) -> bytes:
    descriptor = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
    chunks = []
    copied = 0
    try:
        before = os.fstat(descriptor)
        if not stat.S_ISREG(before.st_mode) or before.st_size > 4 * 1024 * 1024:
            raise SystemExit(1)
        while True:
            chunk = os.read(descriptor, 1024 * 1024)
            if not chunk:
                break
            copied += len(chunk)
            if copied > before.st_size:
                raise SystemExit(1)
            chunks.append(chunk)
        after = os.fstat(descriptor)
        current = os.lstat(path)
        if (
            copied != before.st_size
            or before.st_dev != after.st_dev
            or before.st_ino != after.st_ino
            or before.st_size != after.st_size
            or before.st_mtime_ns != after.st_mtime_ns
            or before.st_ctime_ns != after.st_ctime_ns
            or after.st_dev != current.st_dev
            or after.st_ino != current.st_ino
        ):
            raise SystemExit(1)
        return b"".join(chunks)
    finally:
        os.close(descriptor)


def file_sha256(payload: bytes) -> str:
    digest = hashlib.sha256()
    digest.update(payload)
    return digest.hexdigest()


raw_json = sys.argv[1]
payload_json = sys.argv[2]
attestation_path = Path(sys.argv[3])
destination = Path(sys.argv[4])
evidence = json.loads(raw_json)
payload_evidence = json.loads(payload_json)
attestation_bytes = stable_file_bytes(attestation_path)
attestation = json.loads(attestation_bytes.decode("utf-8"))
if (
    not isinstance(evidence, dict)
    or not isinstance(payload_evidence, dict)
    or not isinstance(attestation, dict)
):
    raise SystemExit(1)
if (
    payload_evidence.get("schema_version") != 1
    or not isinstance(payload_evidence.get("signed_bundles"), list)
    or not payload_evidence["signed_bundles"]
):
    raise SystemExit(1)
for key in ("ipa_sha256", "app_payload_sha256"):
    value = evidence.get(key)
    if (
        not isinstance(value, str)
        or len(value) != 64
        or any(character not in "0123456789abcdef" for character in value)
    ):
        raise SystemExit(1)
if attestation.get("schema_version") != 5:
    raise SystemExit(1)
for key in (
    "archive_payload_sha256",
    "approved_archive_payload_sha256",
    "candidate_evidence_sha256",
    "approval_manifest_sha256",
):
    value = attestation.get(key)
    if (
        not isinstance(value, str)
        or len(value) != 64
        or any(character not in "0123456789abcdef" for character in value)
    ):
        raise SystemExit(1)
if (
    attestation.get("approved_archive_payload_sha256")
    != attestation.get("archive_payload_sha256")
):
    raise SystemExit(1)
output = {
    **evidence,
    "archive_ipa_consistency": payload_evidence,
    "verification_scope": "local_integrity_and_identity_gate_not_release_authorization",
    "archive_attestation_sha256": file_sha256(attestation_bytes),
    "archive_payload_sha256": attestation.get("archive_payload_sha256"),
    "approved_archive_payload_sha256": attestation.get(
        "approved_archive_payload_sha256"
    ),
    "approval_manifest_sha256": attestation.get("approval_manifest_sha256"),
}
flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0)
descriptor = os.open(destination, flags, 0o400)
payload = (
    json.dumps(output, sort_keys=True, separators=(",", ":")) + "\n"
).encode("utf-8")
with os.fdopen(descriptor, "w", encoding="utf-8", closefd=True) as handle:
    handle.write(payload.decode("utf-8"))
    handle.flush()
    os.fsync(handle.fileno())
print(hashlib.sha256(payload).hexdigest())
PY
)" || fail "final verification evidence could not be sealed"

ipa_sha256="$(
  python3 - "$raw_evidence_json" <<'PY'
import json
import sys

value = json.loads(sys.argv[1])
digest = value.get("ipa_sha256") if isinstance(value, dict) else None
if (
    not isinstance(digest, str)
    or len(digest) != 64
    or any(character not in "0123456789abcdef" for character in digest)
):
    raise SystemExit(1)
print(digest)
PY
)" || fail "sealed IPA digest evidence is invalid"
python3 "$snapshot_helper" copy-file \
  "$sealed_snapshot" \
  "$verified_ipa_path" \
  "$ipa_sha256" \
  "$max_ipa_bytes" >/dev/null
chmod 400 "$verified_ipa_path" "$final_evidence"
python3 "$snapshot_helper" promote-delivery \
  "$private_delivery" \
  "$delivery_directory" \
  "$ipa_sha256" \
  "$evidence_sha256" \
  "$max_ipa_bytes"
verified=YES
printf 'PASS: APP2 exported IPA verified and atomically delivered to %s.\n' \
  "$delivery_directory"
}

verify_app2_ipa_main() {
  local ipa_path="${1:-}"
  local archive_path="${2:-}"
  local delivery_directory="${3:-}"
  [[ -n "$ipa_path" && "$ipa_path" == /* &&
     -f "$ipa_path" && ! -L "$ipa_path" ]] ||
    fail "pass one absolute regular IPA path"
  [[ -n "$archive_path" && "$archive_path" == /* &&
     -d "$archive_path" && ! -L "$archive_path" ]] ||
    fail "pass the verified absolute APP2 xcarchive path"
  [[ -n "$delivery_directory" && "$delivery_directory" == /* &&
     ! -e "$delivery_directory" && ! -L "$delivery_directory" ]] ||
    fail "pass one new absolute verified delivery directory"
  exec python3 "$snapshot_helper" exec archive "$archive_path" -- \
    bash -c 'source "$1"; verify_app2_ipa_snapshot "$2" "$3" "$4"' \
    app2-fixed-ipa-verifier "$0" "$ipa_path" "{snapshot}" \
    "$delivery_directory"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  verify_app2_ipa_main "$@"
fi
