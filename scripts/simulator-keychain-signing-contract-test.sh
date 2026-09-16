#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
runner="$script_dir/run-simulator.sh"
verifier="$script_dir/verify-simulator-keychain-contract.sh"
temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/wenxintong-keychain-runner-contract.XXXXXX")"
trap 'rm -rf "$temp_dir"' EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

[[ -x "$runner" ]] || fail "simulator runner is unavailable"
[[ -x "$verifier" ]] || fail "simulator carrier Keychain signing verifier is unavailable"

python3 - "$runner" "$verifier" <<'PY'
from pathlib import Path
import sys

runner_text = Path(sys.argv[1]).read_text(encoding="utf-8")
verifier_text = Path(sys.argv[2]).read_text(encoding="utf-8")

if "CODE_SIGNING_ALLOWED=NO" in runner_text:
    raise SystemExit("FAIL: simulator carrier build disables signing")
for marker in ("codesign", "--verify", "application-identifier", "keychain-access-groups"):
    if marker not in verifier_text:
        raise SystemExit(f"FAIL: signing verifier is missing {marker}")
if "--sign" in verifier_text:
    raise SystemExit("FAIL: verifier must not mutate or re-sign the carrier")
PY

mkdir -p "$temp_dir/bin" "$temp_dir/derived"
command_log="$temp_dir/commands.log"
selected_udid="11111111-2222-3333-4444-555555555555"
other_udid="AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"

cat >"$temp_dir/bin/xcrun" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf 'xcrun %s\n' "$*" >>"${COMMAND_LOG:?}"
if [[ "$*" == "simctl list devices available -j" ]]; then
  printf '%s\n' "${FAKE_DEVICES_JSON:?}"
fi
SH
cat >"$temp_dir/bin/xcodebuild" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf 'xcodebuild %s\n' "$*" >>"${COMMAND_LOG:?}"
derived=""
while [[ $# -gt 0 ]]; do
  if [[ "$1" == "-derivedDataPath" ]]; then
    derived="$2"
    shift 2
    continue
  fi
  shift
done
mkdir -p "$derived/Build/Products/Debug-iphonesimulator/BlueStoneIM.app"
printf 'synthetic plist\n' >"$derived/Build/Products/Debug-iphonesimulator/BlueStoneIM.app/Info.plist"
SH
cat >"$temp_dir/bin/PlistBuddy" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' 'com.wendatongqiye.app'
SH
cat >"$temp_dir/bin/verify-keychain" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf 'verify %s\n' "$1" >>"${COMMAND_LOG:?}"
[[ "${VERIFY_SHOULD_FAIL:-NO}" != "YES" ]] || exit 23
SH
chmod 700 "$temp_dir/bin/xcrun" "$temp_dir/bin/xcodebuild" \
  "$temp_dir/bin/PlistBuddy" "$temp_dir/bin/verify-keychain"

devices_json="{\"devices\":{\"runtime\":[{\"udid\":\"$selected_udid\",\"state\":\"Booted\",\"isAvailable\":true},{\"udid\":\"$other_udid\",\"state\":\"Booted\",\"isAvailable\":true}]}}"
app_path="$temp_dir/derived/Build/Products/Debug-iphonesimulator/BlueStoneIM.app"

run_subject() {
  COMMAND_LOG="$command_log" \
    SIMULATOR_UDID="$selected_udid" \
    DERIVED_DATA_PATH="$temp_dir/derived" \
    XCRUN_TOOL="$temp_dir/bin/xcrun" \
    XCODEBUILD_TOOL="$temp_dir/bin/xcodebuild" \
    PLISTBUDDY_TOOL="$temp_dir/bin/PlistBuddy" \
    VERIFY_KEYCHAIN_CONTRACT="$temp_dir/bin/verify-keychain" \
    VERIFY_SHOULD_FAIL="${VERIFY_SHOULD_FAIL:-NO}" \
    FAKE_DEVICES_JSON="$devices_json" \
    "$runner"
}

: >"$command_log"
if VERIFY_SHOULD_FAIL=YES run_subject >"$temp_dir/failure.log" 2>&1; then
  fail "runner continued after Keychain verifier failure"
fi
[[ "$(grep -c '^verify ' "$command_log" || true)" == "1" ]] ||
  fail "failing Keychain verifier was not executed exactly once"
[[ "$(grep -c '^xcrun simctl install ' "$command_log" || true)" == "0" ]] ||
  fail "verifier failure must cause exactly zero installs"
if grep -Eq '^xcrun simctl (terminate|launch) ' "$command_log"; then
  fail "verifier failure performed a simulator mutation"
fi

: >"$command_log"
VERIFY_SHOULD_FAIL=NO run_subject >"$temp_dir/success.log"
verify_line="$(grep -n '^verify ' "$command_log" | cut -d: -f1)"
install_line="$(grep -n '^xcrun simctl install ' "$command_log" | cut -d: -f1)"
[[ "$verify_line" =~ ^[0-9]+$ && "$install_line" =~ ^[0-9]+$ && "$verify_line" -lt "$install_line" ]] ||
  fail "Keychain verifier did not execute before simctl install"
[[ "$(grep -c '^verify ' "$command_log")" == "1" ]] ||
  fail "Keychain verifier did not execute exactly once"
[[ "$(grep -c '^xcrun simctl install ' "$command_log")" == "1" ]] ||
  fail "successful runner did not install exactly once"
grep -Fq "xcrun simctl terminate $selected_udid com.wendatongqiye.app" "$command_log" ||
  fail "terminate escaped the exact UDID/bundle boundary"
grep -Fq "xcrun simctl install $selected_udid $app_path" "$command_log" ||
  fail "install escaped the exact UDID/app boundary"
grep -Fq "xcrun simctl launch $selected_udid com.wendatongqiye.app" "$command_log" ||
  fail "launch escaped the exact UDID/bundle boundary"
if grep -F "$other_udid" "$command_log" | grep -Ev '^xcrun simctl list devices available -j$' >/dev/null; then
  fail "runner operated on a simulator other than SIMULATOR_UDID"
fi
if grep -Eq '^xcrun simctl (boot|bootstatus|erase|uninstall|delete|shutdown) ' "$command_log"; then
  fail "runner attempted a prohibited simulator lifecycle or data operation"
fi

printf 'PASS: Keychain verification executes before exact-device install and fails with zero installs.\n'
