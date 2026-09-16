#!/usr/bin/env bash
set -euo pipefail

# APP1 keeps its existing release identity. APP2 is deliberately blocked from a
# Release archive until its store identity, audience, channel and signing setup
# have been frozen outside Git. This script receives only non-secret Xcode build
# settings; signing keys and profiles are never read or printed here.
configuration="${CONFIGURATION:-}"
variant="${WXT_APP_VARIANT:-app1}"

fail() {
  printf 'iOS release blocked: %s\n' "$1" >&2
  exit 1
}

if [[ "$configuration" == "Release" && "$variant" == "app1" ]]; then
  effective_bootstrap_url="${WXT_APP_BOOTSTRAP_BASE_URL:-${INFOPLIST_KEY_WXTAppBootstrapBaseURL:-}}"
  effective_bootstrap_backup_url="${WXT_APP_BOOTSTRAP_BACKUP_BASE_URL:-${INFOPLIST_KEY_WXTAppBootstrapBackupBaseURL:-}}"
  effective_app_id="${WXT_PRELOGIN_APP_ID:-}"
  if ! EFFECTIVE_BOOTSTRAP_URL="$effective_bootstrap_url" \
	       EFFECTIVE_BOOTSTRAP_BACKUP_URL="$effective_bootstrap_backup_url" \
	       EFFECTIVE_BOOTSTRAP_URL_1="${WXT_APP_BOOTSTRAP_BASE_URL_1:-}" \
	       EFFECTIVE_BOOTSTRAP_URL_2="${WXT_APP_BOOTSTRAP_BASE_URL_2:-}" \
	       EFFECTIVE_APP_ID="$effective_app_id" \
	       WXT_RELEASE_VARIANT="$variant" python3 <<'PY'
import ipaddress
import os
import re
from urllib.parse import urlsplit

PLACEHOLDERS = ("placeholder", "unconfigured", "changeme", "example.", ".example", ".invalid", "localhost")
FROZEN = {
    "app1": (
	        # JHT_MOD_BEGIN BOOTSTRAP_ANY_ORIGIN_FAILOVER
	        [
	            "bootstrap.wdatong.com",
	            "bootstrap.wdatongcf.com",
	        ],
	        # JHT_MOD_END BOOTSTRAP_ANY_ORIGIN_FAILOVER
        "jianhuitong-ios",
    ),
}

def validate(name: str, raw: str):
    if not raw or raw != raw.strip() or any(token in raw.lower() for token in PLACEHOLDERS):
        raise ValueError(name)
    value = urlsplit(raw)
    if (value.scheme != "https" or not value.hostname or value.username is not None or
            value.password is not None or value.query or value.fragment or value.port not in (None, 443) or
            value.path not in ("", "/")):
        raise ValueError(name)
    host = value.hostname.rstrip(".").lower()
    try:
        ipaddress.ip_address(host)
    except ValueError:
        pass
    else:
        raise ValueError(name)
    if "." not in host or len(host) > 253 or any(
        not re.fullmatch(r"[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?", label)
        for label in host.split(".")
    ):
        raise ValueError(name)
    return host

effective = validate("effective", os.environ["EFFECTIVE_BOOTSTRAP_URL"])
effective_backup = validate("effective backup", os.environ["EFFECTIVE_BOOTSTRAP_BACKUP_URL"])
# JHT_MOD_BEGIN BOOTSTRAP_ANY_ORIGIN_FAILOVER
effective_bases = [
    validate(f"effective {index}", os.environ[f"EFFECTIVE_BOOTSTRAP_URL_{index}"])
    for index in range(1, 3)
]
# JHT_MOD_END BOOTSTRAP_ANY_ORIGIN_FAILOVER
variant = os.environ["WXT_RELEASE_VARIANT"]
if variant not in FROZEN:
    raise ValueError("variant")
expected_hosts, expected_app_id = FROZEN[variant]
app_id = os.environ["EFFECTIVE_APP_ID"]
if (not app_id or app_id != app_id.strip() or
        any(token in app_id.lower() for token in PLACEHOLDERS)):
    raise ValueError("app id")
if len(set(effective_bases)) != len(effective_bases):
    raise ValueError("duplicate bootstrap host")
if (effective_bases != expected_hosts or effective != expected_hosts[0] or
        effective_backup != expected_hosts[1] or app_id != expected_app_id):
    raise ValueError("effective override")
PY
  then
    # JHT_MOD_BEGIN BOOTSTRAP_ANY_ORIGIN_FAILOVER
    fail "current App ordered Bootstrap Hosts and AppId must match its ordered pinned origin set"
    # JHT_MOD_END BOOTSTRAP_ANY_ORIGIN_FAILOVER
  fi
fi

if [[ "$configuration" == "Release-App2" && "$variant" != "app2" ]]; then
  printf 'APP2 release blocked: Release-App2 must build the dedicated app2 variant\n' >&2
  exit 1
fi

if [[ "$variant" != "app2" ]]; then
  exit 0
fi

effective_bootstrap_url="${WXT_APP_BOOTSTRAP_BASE_URL:-${INFOPLIST_KEY_WXTAppBootstrapBaseURL:-}}"
effective_bootstrap_backup_url="${WXT_APP_BOOTSTRAP_BACKUP_BASE_URL:-${INFOPLIST_KEY_WXTAppBootstrapBackupBaseURL:-}}"
[[ -z "$effective_bootstrap_url" ]] ||
  fail "APP2 primary bootstrap URL must remain empty until a future App identity is frozen in code"
[[ -z "$effective_bootstrap_backup_url" ]] ||
  fail "APP2 backup bootstrap URL must remain empty until a future App identity is frozen in code"
for app2_bootstrap_url in \
  "${WXT_APP_BOOTSTRAP_BASE_URL_1:-}" \
  "${WXT_APP_BOOTSTRAP_BASE_URL_2:-}" \
  "${WXT_APP_BOOTSTRAP_BASE_URL_3:-}"; do
  [[ -z "$app2_bootstrap_url" ]] ||
    fail "APP2 ordered bootstrap URL list must remain empty until a future App identity is frozen in code"
done
[[ "${WXT_PRELOGIN_APP_ID:-}" == "WXT_UNCONFIGURED_APP2" ]] ||
  fail "APP2 AppId must remain WXT_UNCONFIGURED_APP2 until its future identity is frozen in code"

if [[ "$configuration" != "Release-App2" ]]; then
  if [[ "$configuration" != "Debug-App2" ]]; then
    printf 'APP2 release blocked: app2 may only use Debug-App2 or Release-App2\n' >&2
    exit 1
  fi
  exit 0
fi

[[ "${WXT_APP2_RELEASE_CONFIGURED:-NO}" == "YES" ]] ||
  fail "set WXT_APP2_RELEASE_CONFIGURED=YES only after the APP2 App ID, certificate and store record are approved"

bundle_id="${PRODUCT_BUNDLE_IDENTIFIER:-}"
app_id="${WXT_PRELOGIN_APP_ID:-}"
access_app_id="${WXT_ACCESS_DISCOVERY_APP_ID:-}"
runtime_app_id="${WXT_APP_RUNTIME_ID:-}"
channel="${WXT_APP_CHANNEL:-}"
display_name="${WXT_APP_DISPLAY_NAME:-}"
signing_boundary="${WXT_APP2_SIGNING_BOUNDARY_ID:-}"
app1_signing_boundary="${WXT_APP1_SIGNING_BOUNDARY_ID:-}"

[[ -n "$bundle_id" && "$bundle_id" != *".unconfigured"* && "$bundle_id" != "com.jianhuitongqiyetest.app" && "$bundle_id" != "com.jianhuitongim.app" ]] ||
  fail "PRODUCT_BUNDLE_IDENTIFIER must be a frozen APP2 identifier distinct from APP1"
[[ -n "$app_id" && "$app_id" != *"UNCONFIGURED"* ]] ||
  fail "WXT_PRELOGIN_APP_ID must be the frozen APP2 bootstrap audience"
[[ -n "$access_app_id" && "$access_app_id" != *"UNCONFIGURED"* ]] ||
  fail "WXT_ACCESS_DISCOVERY_APP_ID must be the frozen APP2 access-discovery audience"
[[ -n "$runtime_app_id" && "$runtime_app_id" != *"UNCONFIGURED"* ]] ||
  fail "WXT_APP_RUNTIME_ID must be the frozen APP2 server App contract identifier"
[[ -n "$channel" && "$channel" != *"unconfigured"* ]] ||
  fail "WXT_APP_CHANNEL must be the frozen APP2 release channel"
[[ -n "$display_name" && "$display_name" != *"未配置"* ]] ||
  fail "WXT_APP_DISPLAY_NAME must be the approved APP2 display name"
[[ "${WXT_PRELOGIN_BOOTSTRAP_ENABLED:-NO}" == "YES" ]] ||
  fail "APP2 release requires trusted prelogin bootstrap"
[[ "${WXT_ACCESS_DISCOVERY_SIGNING_REQUIRED:-NO}" == "YES" ]] ||
  fail "APP2 release requires signed Access Discovery"
[[ -n "${WXT_APP2_TRUST_CONFIGURATION_ID:-}" ]] ||
  fail "WXT_APP2_TRUST_CONFIGURATION_ID must identify the approved three-source/key configuration"
[[ -n "${DEVELOPMENT_TEAM:-}" ]] ||
  fail "APP2 must use an externally selected Apple developer team"
[[ -n "${PROVISIONING_PROFILE_SPECIFIER:-}" ]] ||
  fail "APP2 must use its own externally selected provisioning profile"
[[ -n "${CODE_SIGN_IDENTITY:-}" && "${CODE_SIGN_IDENTITY:-}" != "-" ]] ||
  fail "APP2 must use an externally selected distribution identity"
[[ -n "$signing_boundary" ]] ||
  fail "WXT_APP2_SIGNING_BOUNDARY_ID must identify the approved APP2 certificate/profile boundary"
[[ -z "$app1_signing_boundary" || "$signing_boundary" != "$app1_signing_boundary" ]] ||
  fail "APP2 signing boundary must not reuse APP1"

# Validate the effective trust material, not only an approval/reference id. The
# values are read from Xcode build settings and are never printed. This prevents
# an apparently configured APP2 archive from shipping with empty Info.plist
# arrays or a missing recovery trust root.
if ! python3 <<'PY'
import base64
import binascii
import ipaddress
import json
import os
import sys
from urllib.parse import urlsplit


def require_text(name: str, maximum: int = 256) -> str:
    value = os.environ.get(name, "")
    if not value or value != value.strip() or len(value.encode("utf-8")) > maximum:
        raise ValueError(name)
    if any(character in value for character in "\r\n\t"):
        raise ValueError(name)
    return value


def decode_public_key(value: object) -> bytes:
    if not isinstance(value, str) or not value or len(value) > 128:
        raise ValueError("public key")
    try:
        decoded = base64.b64decode(value, validate=True)
    except (binascii.Error, ValueError):
        raise ValueError("public key") from None
    if len(decoded) != 32:
        raise ValueError("public key")
    return decoded


def decode_key_map(name: str) -> dict[str, str]:
    raw = require_text(name, 16_384)
    value = json.loads(raw)
    if not isinstance(value, dict) or not 1 <= len(value) <= 16:
        raise ValueError(name)
    for key_id, public_key in value.items():
        if not isinstance(key_id, str) or not key_id or key_id != key_id.strip():
            raise ValueError(name)
        if len(key_id.encode("utf-8")) > 128:
            raise ValueError(name)
        decode_public_key(public_key)
    return value


def validate_sources() -> None:
    value = json.loads(require_text("WXT_PRELOGIN_SOURCES_JSON", 16_384))
    if not isinstance(value, list) or len(value) != 3:
        raise ValueError("sources")
    expected_ids = {"primary", "cross-account", "cross-provider"}
    seen_ids: set[str] = set()
    seen_hosts: set[str] = set()
    for item in value:
        if not isinstance(item, dict) or set(item) != {"id", "url"}:
            raise ValueError("sources")
        source_id = item["id"]
        raw_url = item["url"]
        if not isinstance(source_id, str) or not isinstance(raw_url, str):
            raise ValueError("sources")
        parsed = urlsplit(raw_url)
        if (
            parsed.scheme != "https"
            or not parsed.hostname
            or parsed.username is not None
            or parsed.password is not None
            or parsed.query
            or parsed.fragment
            or parsed.port not in (None, 443)
        ):
            raise ValueError("sources")
        try:
            ipaddress.ip_address(parsed.hostname)
        except ValueError:
            pass
        else:
            raise ValueError("sources")
        seen_ids.add(source_id)
        seen_hosts.add(parsed.hostname.lower())
    if seen_ids != expected_ids or len(seen_hosts) != 3:
        raise ValueError("sources")


def main() -> None:
    runtime_app_id = require_text("WXT_APP_RUNTIME_ID", 128)
    prelogin_app_id = require_text("WXT_PRELOGIN_APP_ID", 128)
    access_app_id = require_text("WXT_ACCESS_DISCOVERY_APP_ID", 128)
    channel = require_text("WXT_APP_CHANNEL", 64)
    prelogin_channel = require_text("WXT_PRELOGIN_CHANNEL", 64)
    access_channel = require_text("WXT_ACCESS_DISCOVERY_CHANNEL", 64)
    if len({runtime_app_id, prelogin_app_id, access_app_id}) != 1:
        raise ValueError("app audience")
    if len({channel, prelogin_channel, access_channel}) != 1:
        raise ValueError("channel")
    if require_text("WXT_PRELOGIN_ENVIRONMENT", 32) != require_text(
        "WXT_ACCESS_DISCOVERY_ENVIRONMENT", 32
    ):
        raise ValueError("environment")
    if require_text("WXT_PRELOGIN_PRODUCT_ID", 128) != require_text(
        "WXT_ACCESS_DISCOVERY_PRODUCT_ID", 128
    ):
        raise ValueError("product")
    require_text("WXT_PRELOGIN_RECOVERY_ROOT_KEY_ID", 128)
    decode_public_key(require_text("WXT_PRELOGIN_RECOVERY_ROOT_PUBLIC_KEY_B64", 128))
    require_text("WXT_ACCESS_DISCOVERY_RECOVERY_ROOT_KEY_ID", 128)
    decode_public_key(require_text("WXT_ACCESS_DISCOVERY_RECOVERY_ROOT_PUBLIC_KEY_B64", 128))
    validate_sources()
    decode_key_map("WXT_PRELOGIN_ARTIFACT_PUBLIC_KEYS_JSON")
    decode_key_map("WXT_ACCESS_DISCOVERY_PUBLIC_KEYS_JSON")


try:
    main()
except Exception:
    sys.exit(1)
PY
then
  fail "effective three-source, recovery-root and signature trust material is missing or invalid"
fi
