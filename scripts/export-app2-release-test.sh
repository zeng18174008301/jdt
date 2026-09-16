#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/wenxintong-app2-export-test.XXXXXX")"
trap 'rm -rf "$temp_dir"' EXIT

fail() {
  printf 'APP2 export workflow test failed: %s\n' "$1" >&2
  exit 1
}

mkdir -p "$temp_dir/scripts" "$temp_dir/bin" "$temp_dir/archive.xcarchive"
cp "$script_dir/export-app2-release.sh" "$temp_dir/scripts/export-app2-release.sh"
cp "$script_dir/app2_filesystem_snapshot.py" "$temp_dir/scripts/app2_filesystem_snapshot.py"
touch "$temp_dir/ExportOptions.plist"

cat >"$temp_dir/scripts/verify-app2-release-package.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
[[ "${1:-}" == */.wenxintong-app2-sealed.*/tree ]]
SH
cat >"$temp_dir/scripts/verify-app2-ipa.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
[[ "${FAKE_IPA_VERIFY_FAIL:-NO}" != "YES" ]] || exit 1
[[ "${2:-}" == */.wenxintong-app2-sealed.*/tree ]]
delivery="${3:?}"
if [[ -n "${FAKE_RACE_OUTPUT:-}" ]]; then
  mkdir "$FAKE_RACE_OUTPUT"
  if [[ "${FAKE_RACE_OUTPUT_KIND:-marker}" == "marker" ]]; then
    touch "$FAKE_RACE_OUTPUT/concurrent-owner"
  fi
fi
[[ ! -e "$delivery" ]] || exit 1
mkdir "$delivery"
printf '{"verified":true}\n' >"$delivery/APP2_IPA_VERIFICATION.json"
printf 'sealed-verified-ipa\n' >"$delivery/WenxintongApp2.ipa"
chmod 400 \
  "$delivery/APP2_IPA_VERIFICATION.json" \
  "$delivery/WenxintongApp2.ipa"
SH
cat >"$temp_dir/bin/xcodebuild" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
export_path=""
while [[ "$#" -gt 0 ]]; do
  if [[ "$1" == "-exportPath" ]]; then
    export_path="$2"
    shift 2
    continue
  fi
  shift
done
[[ -n "$export_path" ]] || exit 2
case "${FAKE_EXPORT_MODE:-one}" in
  none) ;;
  one) touch "$export_path/app2.ipa" ;;
  multi) touch "$export_path/app2-a.ipa" "$export_path/app2-b.ipa" ;;
  linked)
    touch "$export_path/app2.ipa"
    ln -s app2.ipa "$export_path/linked.ipa"
    ;;
  *) exit 3 ;;
esac
SH
chmod 700 \
  "$temp_dir/scripts/export-app2-release.sh" \
  "$temp_dir/scripts/app2_filesystem_snapshot.py" \
  "$temp_dir/scripts/verify-app2-release-package.sh" \
  "$temp_dir/scripts/verify-app2-ipa.sh" \
  "$temp_dir/bin/xcodebuild"

run_export() {
  local output="$1"
  PATH="$temp_dir/bin:$PATH" \
    "$temp_dir/scripts/export-app2-release.sh" \
    "$temp_dir/archive.xcarchive" \
    "$temp_dir/ExportOptions.plist" \
    "$output"
}

mkdir "$temp_dir/existing-output"
if run_export "$temp_dir/existing-output" >"$temp_dir/existing.log" 2>&1; then
  fail "pre-existing output directory unexpectedly passed"
fi

forged_fd=9
exec 9<"$temp_dir/archive.xcarchive"
read -r forged_dev forged_ino < <(
  python3 - "$forged_fd" <<'PY'
import os
import sys

state = os.fstat(int(sys.argv[1]))
print(state.st_dev, state.st_ino)
PY
)
if ! APP2_ARCHIVE_IS_SEALED_SNAPSHOT=YES \
  APP2_SEALED_SNAPSHOT="$temp_dir/archive.xcarchive" \
  APP2_SEALED_SNAPSHOT_FD="$forged_fd" \
  APP2_SEALED_SNAPSHOT_DEV="$forged_dev" \
  APP2_SEALED_SNAPSHOT_INO="$forged_ino" \
  run_export "$temp_dir/forged-snapshot-output" \
  >"$temp_dir/forged-snapshot.log" 2>&1; then
  fail "valid caller-forged snapshot environment altered the fixed helper path"
fi
exec 9<&-
[[ -f "$temp_dir/forged-snapshot-output/WenxintongApp2.ipa" ]] ||
  fail "fixed snapshot workflow did not ignore caller-forged descriptor state"

for mode in none multi linked; do
  output="$temp_dir/$mode-output"
  if FAKE_EXPORT_MODE="$mode" run_export "$output" >"$temp_dir/$mode.log" 2>&1; then
    fail "$mode IPA export unexpectedly passed"
  fi
  [[ ! -e "$output" ]] ||
    fail "$mode IPA failure left a deliverable output directory"
done

if FAKE_IPA_VERIFY_FAIL=YES run_export "$temp_dir/verify-failure-output" \
  >"$temp_dir/verify-failure.log" 2>&1; then
  fail "failed IPA verification unexpectedly passed"
fi
[[ ! -e "$temp_dir/verify-failure-output" ]] ||
  fail "failed IPA verification left a deliverable output directory"

race_output="$temp_dir/race-output"
if FAKE_RACE_OUTPUT="$race_output" run_export "$race_output" \
  >"$temp_dir/race.log" 2>&1; then
  fail "concurrent output target unexpectedly passed"
fi
[[ -f "$race_output/concurrent-owner" &&
   ! -e "$race_output/app2.ipa" &&
   ! -e "$race_output/deliverable" ]] ||
  fail "concurrent output target was overwritten or received nested export output"

empty_race_output="$temp_dir/empty-race-output"
if FAKE_RACE_OUTPUT="$empty_race_output" FAKE_RACE_OUTPUT_KIND=empty \
  run_export "$empty_race_output" >"$temp_dir/empty-race.log" 2>&1; then
  fail "concurrent empty output target unexpectedly passed"
fi
[[ -d "$empty_race_output" ]] ||
  fail "concurrent empty output directory was overwritten"
if find "$empty_race_output" -mindepth 1 -print -quit | grep -q .; then
  fail "concurrent empty output directory received partial delivery content"
fi

run_export "$temp_dir/success-output" >"$temp_dir/success.log"
[[ -f "$temp_dir/success-output/WenxintongApp2.ipa" &&
   ! -L "$temp_dir/success-output/WenxintongApp2.ipa" &&
   -f "$temp_dir/success-output/APP2_IPA_VERIFICATION.json" &&
   ! -L "$temp_dir/success-output/APP2_IPA_VERIFICATION.json" &&
   ! -e "$temp_dir/success-output/app2.ipa" ]] ||
  fail "verified export was not atomically delivered with evidence"
if find "$temp_dir" -maxdepth 1 -name '.wenxintong-app2-export-stage.*' -print -quit |
  grep -q .; then
  fail "export workflow left a staging directory"
fi

printf 'PASS: APP2 export rejects stale/partial/multiple/unverified/racing output, preserves empty concurrent targets and atomically delivers one sealed verified IPA.\n'
