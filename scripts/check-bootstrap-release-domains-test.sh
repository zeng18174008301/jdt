#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
gate="$script_dir/check-app2-release-configuration.sh"

app1_1="https://bootstrap.wdatong.com"
# JHT_MOD_BEGIN BOOTSTRAP_ANY_ORIGIN_FAILOVER
app1_2="https://bootstrap.wdatongcf.com"
# JHT_MOD_END BOOTSTRAP_ANY_ORIGIN_FAILOVER

run_app1() {
  local url_1="${1:?}"
  local url_2="${2:?}"
  local app_id="${3:?}"
  local legacy_primary="${4-$url_1}"
  local legacy_backup="${5-$url_2}"
  CONFIGURATION=Release \
  WXT_APP_VARIANT=app1 \
  INFOPLIST_KEY_WXTAppBootstrapBaseURL="$legacy_primary" \
  WXT_APP_BOOTSTRAP_BASE_URL="$legacy_primary" \
  INFOPLIST_KEY_WXTAppBootstrapBackupBaseURL="$legacy_backup" \
  WXT_APP_BOOTSTRAP_BACKUP_BASE_URL="$legacy_backup" \
  WXT_APP_BOOTSTRAP_BASE_URL_1="$url_1" \
  WXT_APP_BOOTSTRAP_BASE_URL_2="$url_2" \
  WXT_PRELOGIN_APP_ID="$app_id" \
  "$gate"
}

run_app1 "$app1_1" "$app1_2" "jianhuitong-ios"

for invalid in \
  "https://wrong-bootstrap.wdatong.com" \
  "http://bootstrap.wdatong.com" \
  "https://127.0.0.1" \
  "https://placeholder.example.com" \
  "https://bootstrap.wdatong.com:444" \
  "https://bootstrap.wdatong.com/path"; do
  if run_app1 "$invalid" "$app1_2" "jianhuitong-ios" >/dev/null 2>&1; then
    printf 'release bootstrap domain test failed: invalid URL passed: %s\n' "$invalid" >&2
    exit 1
  fi
done

if run_app1 "$app1_2" "$app1_1" "jianhuitong-ios" >/dev/null 2>&1; then
  printf 'release bootstrap domain test failed: reordered App1 origins passed\n' >&2
  exit 1
fi
if run_app1 "$app1_1" "$app1_1" "jianhuitong-ios" >/dev/null 2>&1; then
  printf 'release bootstrap domain test failed: duplicate App1 host passed\n' >&2
  exit 1
fi
if run_app1 "$app1_1" "$app1_2" "different-app-id" >/dev/null 2>&1; then
  # JHT_MOD_BEGIN BOOTSTRAP_ANY_ORIGIN_FAILOVER
  printf 'release bootstrap domain test failed: external AppId override bypassed ordered pinned origin set\n' >&2
  # JHT_MOD_END BOOTSTRAP_ANY_ORIGIN_FAILOVER
  exit 1
fi
if run_app1 \
  "$app1_1" "$app1_2" "jianhuitong-ios" \
  "https://future-bootstrap.wdatong.com" "$app1_2" >/dev/null 2>&1; then
  printf 'release bootstrap domain test failed: legacy primary alias diverged from ordered list\n' >&2
  exit 1
fi

CONFIGURATION=Debug-App2 \
WXT_APP_VARIANT=app2 \
INFOPLIST_KEY_WXTAppBootstrapBaseURL="" \
WXT_APP_BOOTSTRAP_BASE_URL="" \
INFOPLIST_KEY_WXTAppBootstrapBackupBaseURL="" \
WXT_APP_BOOTSTRAP_BACKUP_BASE_URL="" \
WXT_APP_BOOTSTRAP_BASE_URL_1="" \
WXT_APP_BOOTSTRAP_BASE_URL_2="" \
WXT_APP_BOOTSTRAP_BASE_URL_3="" \
WXT_PRELOGIN_APP_ID="WXT_UNCONFIGURED_APP2" \
"$gate"

app2_override_error="$({
  CONFIGURATION=Debug-App2 \
  WXT_APP_VARIANT=app2 \
  INFOPLIST_KEY_WXTAppBootstrapBaseURL="" \
  WXT_APP_BOOTSTRAP_BASE_URL="" \
  INFOPLIST_KEY_WXTAppBootstrapBackupBaseURL="" \
  WXT_APP_BOOTSTRAP_BACKUP_BASE_URL="" \
  WXT_APP_BOOTSTRAP_BASE_URL_1="https://future-bootstrap.wenxintongim.com" \
  WXT_APP_BOOTSTRAP_BASE_URL_2="" \
  WXT_APP_BOOTSTRAP_BASE_URL_3="" \
  WXT_PRELOGIN_APP_ID="WXT_UNCONFIGURED_APP2" \
  "$gate"
} 2>&1 || true)"
if [[ "$app2_override_error" != *"ordered bootstrap URL list must remain empty"* ]]; then
  printf 'release bootstrap domain test failed: App2 nonempty ordered list did not hit the empty-URL gate\n' >&2
  exit 1
fi

app2_release_error="$({
  CONFIGURATION=Release-App2 \
  WXT_APP_VARIANT=app2 \
  INFOPLIST_KEY_WXTAppBootstrapBaseURL="" \
  WXT_APP_BOOTSTRAP_BASE_URL="" \
  INFOPLIST_KEY_WXTAppBootstrapBackupBaseURL="" \
  WXT_APP_BOOTSTRAP_BACKUP_BASE_URL="" \
  WXT_APP_BOOTSTRAP_BASE_URL_1="" \
  WXT_APP_BOOTSTRAP_BASE_URL_2="" \
  WXT_APP_BOOTSTRAP_BASE_URL_3="" \
  WXT_PRELOGIN_APP_ID="WXT_UNCONFIGURED_APP2" \
  "$gate"
} 2>&1 || true)"
if [[ "$app2_release_error" != *"set WXT_APP2_RELEASE_CONFIGURED=YES"* ]]; then
  printf 'release bootstrap domain test failed: empty/unconfigured App2 did not remain release-blocked\n' >&2
  exit 1
fi

# JHT_MOD_BEGIN BOOTSTRAP_ANY_ORIGIN_FAILOVER
printf 'PASS: App1 uses its frozen ordered pinned iOS bootstrap origin set; App2 remains empty and release-blocked.\n'
# JHT_MOD_END BOOTSTRAP_ANY_ORIGIN_FAILOVER
