#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
snapshot_helper="$script_dir/app2_filesystem_snapshot.py"
attestation_helper="$script_dir/app2-release-attestation.py"

fail() {
  printf 'APP2 archive blocked: %s\n' "$1" >&2
  exit 1
}

verify_app2_archive_snapshot() {
local app_path="${1:-}"
[[ -d "$app_path" && -f "$app_path/Info.plist" ]] ||
  fail "pass the final archived APP2 .app directory"

codesign --verify --deep --strict "$app_path" >/dev/null 2>&1 ||
  fail "final app code signature is invalid"
app_executable="$(
  python3 - "$app_path/Info.plist" <<'PY'
import plistlib
import sys
from pathlib import Path

with Path(sys.argv[1]).open("rb") as handle:
    info = plistlib.load(handle)
value = info.get("CFBundleExecutable") if isinstance(info, dict) else None
if (
    not isinstance(value, str)
    or not value
    or value in {".", ".."}
    or "/" in value
    or "\\" in value
    or any(ord(character) < 0x20 or ord(character) == 0x7F for character in value)
):
    raise SystemExit(1)
print(value)
PY
)" || fail "final app executable identity is invalid"
[[ -f "$app_path/$app_executable" && ! -L "$app_path/$app_executable" ]] ||
  fail "final app executable is missing"
if ! python3 - "$app_path/Info.plist" <<'PY'
import plistlib
import sys
from pathlib import Path

with Path(sys.argv[1]).open("rb") as handle:
    info = plistlib.load(handle)
if not isinstance(info, dict) or info.get("WXTAccessDiagnosticsOverlayCompiled") != "YES":
    raise SystemExit(1)
PY
then
  fail "formal archive is missing diagnostics capability metadata"
fi
if ! python3 - "$app_path/$app_executable" <<'PY'
import sys
from pathlib import Path

marker = b"WXT_ACCESS_DIAGNOSTICS_OVERLAY_BINARY_MARKER_V1"
with Path(sys.argv[1]).open("rb") as handle:
    carry = b""
    while chunk := handle.read(1024 * 1024):
        value = carry + chunk
        if marker in value:
            raise SystemExit(0)
        carry = value[-(len(marker) - 1):]
raise SystemExit(1)
PY
then
  fail "formal archive is missing the diagnostics capability marker"
fi

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT
if [[ "${APP2_CANDIDATE_BUILD:-NO}" == "YES" ]]; then
  printf 'PASS: APP2 candidate signature and diagnostics capability verified.\n'
  exit 0
fi
manifest_json="$(python3 "$attestation_helper" manifest)" ||
  fail "the repository-trusted APP2 approval manifest is not available"
codesign -d --entitlements :- "$app_path" >"$tmp_dir/entitlements.plist" 2>/dev/null ||
  fail "cannot read final signed entitlements"
[[ -f "$app_path/embedded.mobileprovision" ]] ||
  fail "final archive is missing embedded.mobileprovision"
security cms -D -i "$app_path/embedded.mobileprovision" >"$tmp_dir/profile.plist" 2>/dev/null ||
  fail "cannot decode final provisioning profile"
codesign -d --extract-certificates "$tmp_dir/signing-cert" "$app_path" >/dev/null 2>&1 ||
  fail "cannot extract the final signing certificate"
[[ -f "$tmp_dir/signing-cert0" ]] ||
  fail "final signature has no leaf signing certificate"
signing_certificate_sha256="$(shasum -a 256 "$tmp_dir/signing-cert0" | awk '{print $1}')"

if ! python3 - \
  "$app_path/Info.plist" \
  "$tmp_dir/entitlements.plist" \
  "$tmp_dir/profile.plist" \
  "$manifest_json" \
  "$signing_certificate_sha256" <<'PY'
import base64
import binascii
import datetime
import hashlib
import json
import plistlib
import sys
from pathlib import Path
from urllib.parse import urlsplit


def fail(message: str) -> None:
    raise ValueError(message)


def load_plist(path: str) -> dict:
    with Path(path).open("rb") as handle:
        value = plistlib.load(handle)
    if not isinstance(value, dict):
        fail("plist")
    return value


def text(value: object) -> str:
    if not isinstance(value, str) or not value or value != value.strip():
        fail("text")
    return value


def enabled(value: object) -> bool:
    return value is True or str(value).lower() in {"yes", "true", "1", "on"}


def key_hash(value: object) -> str:
    try:
        decoded = base64.b64decode(text(value), validate=True)
    except (binascii.Error, ValueError):
        fail("public key")
    if len(decoded) != 32:
        fail("public key")
    return hashlib.sha256(decoded).hexdigest()


info = load_plist(sys.argv[1])
entitlements = load_plist(sys.argv[2])
profile = load_plist(sys.argv[3])
manifest = json.loads(sys.argv[4])
if not isinstance(manifest, dict):
    fail("manifest")

required = {
    "bundle_id", "runtime_app_id", "channel", "environment", "product_id",
    "team_id", "aps_environment", "provisioning_profile_uuid",
    "signing_certificate_sha256", "prelogin_recovery_root_key_id",
    "prelogin_recovery_root_public_key_sha256",
    "access_recovery_root_key_id", "access_recovery_root_public_key_sha256",
    "three_source_hosts", "approved_archive_payload_sha256",
}
if set(manifest) != required:
    fail("manifest schema")
approved_archive_payload_sha256 = text(
    manifest["approved_archive_payload_sha256"]
)
if (
    len(approved_archive_payload_sha256) != 64
    or any(
        character not in "0123456789abcdef"
        for character in approved_archive_payload_sha256
    )
):
    fail("approved archive payload hash")

bundle_id = text(info.get("CFBundleIdentifier"))
runtime_app_id = text(info.get("WXTAppRuntimeID"))
channel = text(info.get("WXTAccessDiscoveryChannel"))
environment = text(info.get("WXTAccessDiscoveryEnvironment"))
product_id = text(info.get("WXTAccessDiscoveryProductID"))
if (
    info.get("WXTAppVariant") != "app2"
    or info.get("WXTAccessDiagnosticsOverlayCompiled") != "YES"
    or not enabled(info.get("WXTPreloginBootstrapEnabled"))
    or not enabled(info.get("WXTAccessDiscoverySigningRequired"))
    or info.get("WXTPreloginBootstrapAppID") != runtime_app_id
    or info.get("WXTAccessDiscoveryAppID") != runtime_app_id
    or info.get("WXTPreloginBootstrapChannel") != channel
    or info.get("WXTPreloginBootstrapEnvironment") != environment
    or info.get("WXTPreloginBootstrapProductID") != product_id
):
    fail("final Info.plist identity/trust mismatch")

for key, actual in {
    "bundle_id": bundle_id,
    "runtime_app_id": runtime_app_id,
    "channel": channel,
    "environment": environment,
    "product_id": product_id,
    "prelogin_recovery_root_key_id": text(info.get("WXTPreloginBootstrapRecoveryRootKeyID")),
    "access_recovery_root_key_id": text(info.get("WXTAccessDiscoveryRecoveryRootKeyID")),
}.items():
    if manifest[key] != actual:
        fail(key)
if manifest["prelogin_recovery_root_public_key_sha256"] != key_hash(
    info.get("WXTPreloginBootstrapRecoveryRootPublicKeyBase64")
):
    fail("prelogin recovery root fingerprint")
if manifest["access_recovery_root_public_key_sha256"] != key_hash(
    info.get("WXTAccessDiscoveryRecoveryRootPublicKeyB64")
):
    fail("access recovery root fingerprint")

sources = json.loads(text(info.get("WXTPreloginBootstrapSourcesJSON")))
if not isinstance(sources, list) or len(sources) != 3:
    fail("three sources")
source_hosts = []
for source in sources:
    if not isinstance(source, dict) or set(source) != {"id", "url"}:
        fail("three sources")
    parsed = urlsplit(text(source["url"]))
    if parsed.scheme != "https" or not parsed.hostname or parsed.query or parsed.fragment:
        fail("three sources")
    source_hosts.append(parsed.hostname.lower())
if sorted(source_hosts) != sorted(manifest["three_source_hosts"]) or len(set(source_hosts)) != 3:
    fail("three source host manifest")

team_id = text(manifest["team_id"])
application_identifier = text(entitlements.get("application-identifier"))
if application_identifier != f"{team_id}.{bundle_id}":
    fail("application identifier")
if entitlements.get("com.apple.developer.team-identifier") != team_id:
    fail("team identifier")
if entitlements.get("aps-environment") != manifest["aps_environment"]:
    fail("push entitlement")
if entitlements.get("get-task-allow") not in {None, False}:
    fail("debug entitlement")
profile_entitlements = profile.get("Entitlements")
if not isinstance(profile_entitlements, dict):
    fail("profile entitlements")
if profile_entitlements.get("com.apple.developer.team-identifier") != team_id:
    fail("profile team")
if profile_entitlements.get("aps-environment") != manifest["aps_environment"]:
    fail("profile push entitlement")
if profile_entitlements.get("application-identifier") != application_identifier:
    fail("profile application identifier")
if profile_entitlements.get("get-task-allow") not in {None, False}:
    fail("profile debug entitlement")
if text(profile.get("UUID")) != text(manifest["provisioning_profile_uuid"]):
    fail("provisioning profile UUID")
certificate_hash = text(sys.argv[5])
if len(certificate_hash) != 64 or any(character not in "0123456789abcdef" for character in certificate_hash):
    fail("signing certificate hash")
if certificate_hash != text(manifest["signing_certificate_sha256"]):
    fail("signing certificate")
expiration = profile.get("ExpirationDate")
if not isinstance(expiration, datetime.datetime):
    fail("provisioning profile expiry")
if expiration.tzinfo is None:
    expiration = expiration.replace(tzinfo=datetime.timezone.utc)
if expiration <= datetime.datetime.now(datetime.timezone.utc):
    fail("provisioning profile expiry")
developer_certificates = profile.get("DeveloperCertificates")
if (
    not isinstance(developer_certificates, list)
    or certificate_hash not in {
        hashlib.sha256(bytes(certificate)).hexdigest()
        for certificate in developer_certificates
        if isinstance(certificate, (bytes, bytearray))
    }
):
    fail("provisioning profile signing certificate")
PY
then
  fail "final archive identity, entitlements or trust manifest mismatch"
fi

printf 'PASS: APP2 final archive identity, provisioning, push and trust manifest verified.\n'
}

verify_app2_archive_main() {
  local app_path="${1:-}"
  [[ -d "$app_path" && -f "$app_path/Info.plist" ]] ||
    fail "pass the final archived APP2 .app directory"
  exec python3 "$snapshot_helper" exec app "$app_path" -- \
    bash -c 'source "$1"; verify_app2_archive_snapshot "$2"' \
    app2-fixed-archive-verifier "$0" "{snapshot}"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  verify_app2_archive_main "$@"
fi
