#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/wenxintong-ios1-simulator-test.XXXXXX")"
trap 'rm -rf "$temp_dir"' EXIT

fail() {
  printf 'iOS1 simulator runner test failed: %s\n' "$1" >&2
  exit 1
}

mkdir -p "$temp_dir/bin" "$temp_dir/derived"
command_log="$temp_dir/commands.log"
selected_udid="11111111-2222-3333-4444-555555555555"
other_udid="AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"

run_subject() {
  COMMAND_LOG="$command_log" \
    SIMULATOR_UDID="${SIMULATOR_UDID-}" \
    DERIVED_DATA_PATH="$temp_dir/derived" \
    XCRUN_TOOL="$temp_dir/bin/xcrun" \
    XCODEBUILD_TOOL="$temp_dir/bin/xcodebuild" \
    PLISTBUDDY_TOOL="$temp_dir/bin/PlistBuddy" \
    VERIFY_KEYCHAIN_CONTRACT="$temp_dir/bin/verify-keychain" \
    FAKE_DEVICES_JSON="${FAKE_DEVICES_JSON-}" \
    FAKE_BUNDLE_ID="${FAKE_BUNDLE_ID-com.wendatongqiye.app}" \
    "$script_dir/run-simulator.sh" "$@"
}

if env -u SIMULATOR_UDID \
  DERIVED_DATA_PATH="$temp_dir/derived" \
  XCRUN_TOOL="$temp_dir/bin/xcrun" \
  "$script_dir/run-simulator.sh" >"$temp_dir/missing.log" 2>&1; then
  fail "missing SIMULATOR_UDID unexpectedly passed"
fi

# The helper executables are generated after the missing-UDID check so that the
# fail-closed case also proves no external command was needed.
printf '%s\n' '#!/usr/bin/env bash' 'set -euo pipefail' \
  'printf "xcrun %s\\n" "$*" >>"${COMMAND_LOG:?}"' \
  'if [[ "$*" == "simctl list devices available -j" ]]; then' \
  '  printf "%s\\n" "${FAKE_DEVICES_JSON:?}"' \
  'fi' >"$temp_dir/bin/xcrun"
printf '%s\n' '#!/usr/bin/env bash' 'set -euo pipefail' \
  'printf "xcodebuild %s\\n" "$*" >>"${COMMAND_LOG:?}"' \
  'derived=""' \
  'while [[ $# -gt 0 ]]; do' \
  '  if [[ "$1" == "-derivedDataPath" ]]; then derived="$2"; shift 2; continue; fi' \
  '  shift' \
  'done' \
  'mkdir -p "$derived/Build/Products/Debug-iphonesimulator/BlueStoneIM.app"' \
  'printf "plist\\n" >"$derived/Build/Products/Debug-iphonesimulator/BlueStoneIM.app/Info.plist"' \
  >"$temp_dir/bin/xcodebuild"
printf '%s\n' '#!/usr/bin/env bash' 'set -euo pipefail' \
  'printf "%s\\n" "${FAKE_BUNDLE_ID:?}"' >"$temp_dir/bin/PlistBuddy"
printf '%s\n' '#!/usr/bin/env bash' 'set -euo pipefail' \
  'printf "verify %s\\n" "$1" >>"${COMMAND_LOG:?}"' >"$temp_dir/bin/verify-keychain"
chmod 700 "$temp_dir/bin/xcrun" "$temp_dir/bin/xcodebuild" \
  "$temp_dir/bin/PlistBuddy" "$temp_dir/bin/verify-keychain"

wrong_inventory="{\"devices\":{\"runtime\":[{\"udid\":\"$other_udid\",\"state\":\"Booted\",\"isAvailable\":true}]}}"
: >"$command_log"
if SIMULATOR_UDID="$selected_udid" FAKE_DEVICES_JSON="$wrong_inventory" \
  run_subject >"$temp_dir/wrong-udid.log" 2>&1; then
  fail "an unlisted SIMULATOR_UDID unexpectedly passed"
fi
[[ "$(wc -l <"$command_log" | tr -d ' ')" == "1" ]] ||
  fail "wrong UDID performed an operation after inventory readback"

shutdown_inventory="{\"devices\":{\"runtime\":[{\"udid\":\"$selected_udid\",\"state\":\"Shutdown\",\"isAvailable\":true}]}}"
: >"$command_log"
if SIMULATOR_UDID="$selected_udid" FAKE_DEVICES_JSON="$shutdown_inventory" \
  run_subject >"$temp_dir/shutdown.log" 2>&1; then
  fail "a non-booted dedicated simulator unexpectedly passed"
fi
[[ "$(wc -l <"$command_log" | tr -d ' ')" == "1" ]] ||
  fail "non-booted simulator performed an operation after inventory readback"

valid_inventory="{\"devices\":{\"runtime\":[{\"udid\":\"$selected_udid\",\"state\":\"Booted\",\"isAvailable\":true},{\"udid\":\"$other_udid\",\"state\":\"Booted\",\"isAvailable\":true}]}}"
: >"$command_log"
if SIMULATOR_UDID="$selected_udid" FAKE_DEVICES_JSON="$valid_inventory" \
  FAKE_BUNDLE_ID="wrong.example.test" run_subject >"$temp_dir/wrong-bundle.log" 2>&1; then
  fail "a built app with the wrong bundle identifier unexpectedly passed"
fi
if grep -Eq 'simctl (terminate|install|launch)' "$command_log"; then
  fail "wrong bundle readback performed a simulator mutation"
fi

: >"$command_log"
SIMULATOR_UDID="$selected_udid" FAKE_DEVICES_JSON="$valid_inventory" \
  FAKE_BUNDLE_ID="com.wendatongqiye.app" run_subject >"$temp_dir/success.log"

grep -Fq "simctl terminate $selected_udid com.wendatongqiye.app" "$command_log" ||
  fail "terminate did not use exact UDID and bundle readback"
grep -Fq "simctl install $selected_udid $temp_dir/derived/Build/Products/Debug-iphonesimulator/BlueStoneIM.app" "$command_log" ||
  fail "install did not use exact UDID and built app path"
grep -Fq "simctl launch $selected_udid com.wendatongqiye.app" "$command_log" ||
  fail "launch did not use exact UDID and bundle readback"
if grep -Eq 'simctl (boot|bootstatus|erase|uninstall|delete|shutdown)' "$command_log"; then
  fail "runner attempted a prohibited simulator lifecycle or data operation"
fi
if grep -F "$other_udid" "$command_log" | grep -Ev 'simctl list devices available -j' >/dev/null; then
  fail "runner operated on a simulator other than SIMULATOR_UDID"
fi

printf 'PASS: iOS1 simulator runner is explicit-UDID, readback-bound and data-preserving.\n'
