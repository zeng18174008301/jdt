#!/usr/bin/env bash
set -euo pipefail

fail() {
  printf 'iOS1 simulator run blocked: %s\n' "$1" >&2
  exit 1
}

[[ $# -eq 0 ]] || fail "do not pass a device name; set SIMULATOR_UDID to the dedicated simulator"

simulator_udid="${SIMULATOR_UDID:-}"
[[ "$simulator_udid" =~ ^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$ ]] ||
  fail "SIMULATOR_UDID must be the explicit dedicated simulator UUID"

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
app_dir="$(cd "$script_dir/.." && pwd)"
project="$app_dir/BlueStoneIM.xcodeproj"
scheme="BlueStoneIM"
expected_bundle_id="com.wendatongqiye.app"
derived_data="${DERIVED_DATA_PATH:-${TMPDIR:-/tmp}/wenxintong-ios1-derived-$simulator_udid}"
app_path="$derived_data/Build/Products/Debug-iphonesimulator/BlueStoneIM.app"
xcrun_tool="${XCRUN_TOOL:-/usr/bin/xcrun}"
xcodebuild_tool="${XCODEBUILD_TOOL:-/usr/bin/xcodebuild}"
plistbuddy_tool="${PLISTBUDDY_TOOL:-/usr/libexec/PlistBuddy}"
verify_keychain_contract="${VERIFY_KEYCHAIN_CONTRACT:-$script_dir/verify-simulator-keychain-contract.sh}"

[[ "$derived_data" == /* && ! -L "$derived_data" ]] ||
  fail "DERIVED_DATA_PATH must be an absolute non-linked path"
[[ -x "$xcrun_tool" ]] || fail "xcrun is unavailable"
[[ -x "$xcodebuild_tool" ]] || fail "xcodebuild is unavailable"
[[ -x "$plistbuddy_tool" ]] || fail "PlistBuddy is unavailable"
[[ -x "$verify_keychain_contract" ]] || fail "simulator keychain verifier is unavailable"

devices_json="$($xcrun_tool simctl list devices available -j)" ||
  fail "could not read the available simulator inventory"
device_state="$(SIMULATOR_UDID="$simulator_udid" /usr/bin/python3 -c '
import json
import os
import sys

target = os.environ["SIMULATOR_UDID"]
try:
    payload = json.load(sys.stdin)
except (json.JSONDecodeError, TypeError, ValueError):
    raise SystemExit(2)
matches = [
    device
    for devices in payload.get("devices", {}).values()
    if isinstance(devices, list)
    for device in devices
    if isinstance(device, dict)
    and device.get("udid") == target
    and device.get("isAvailable", True) is not False
]
if len(matches) != 1:
    raise SystemExit(1)
state = matches[0].get("state")
if not isinstance(state, str):
    raise SystemExit(1)
print(state)
' <<<"$devices_json")" || fail "SIMULATOR_UDID is not one exact available simulator"
[[ "$device_state" == "Booted" ]] ||
  fail "the dedicated simulator must already be Booted; this script never boots devices"

"$xcodebuild_tool" \
  -project "$project" \
  -scheme "$scheme" \
  -sdk iphonesimulator \
  -destination "id=$simulator_udid" \
  -configuration Debug \
  -derivedDataPath "$derived_data" \
  CODE_SIGNING_ALLOWED=YES \
  build

[[ -d "$app_path" && ! -L "$app_path" && -f "$app_path/Info.plist" ]] ||
  fail "build succeeded but the expected app bundle was not found"

built_bundle_id="$($plistbuddy_tool -c 'Print :CFBundleIdentifier' "$app_path/Info.plist" 2>/dev/null)" ||
  fail "could not read CFBundleIdentifier from the built app"
[[ "$built_bundle_id" == "$expected_bundle_id" ]] ||
  fail "built app bundle identifier does not match the iOS1 simulator contract"

"$verify_keychain_contract" "$app_path"

# Installing over the existing app preserves its data. Reset/erase/uninstall is a
# separate destructive operation and is intentionally not implemented here.
"$xcrun_tool" simctl terminate "$simulator_udid" "$built_bundle_id" >/dev/null 2>&1 || true
"$xcrun_tool" simctl install "$simulator_udid" "$app_path"
"$xcrun_tool" simctl launch "$simulator_udid" "$built_bundle_id"

printf 'iOS1 launched on the explicitly selected dedicated simulator.\n'
