#!/usr/bin/env bash
set -euo pipefail
umask 077

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
snapshot_helper="$script_dir/app2_filesystem_snapshot.py"

fail() {
  printf 'APP2 release export blocked: %s\n' "$1" >&2
  exit 1
}

export_app2_release_snapshot() {
local archive_path="${1:-}"
local export_options_plist="${2:-}"
local output_directory="${3:-}"
[[ -n "$archive_path" && "$archive_path" == /* &&
   -d "$archive_path" && ! -L "$archive_path" ]] ||
  fail "pass the final absolute APP2 xcarchive path"
[[ -n "$export_options_plist" && "$export_options_plist" == /* &&
   -f "$export_options_plist" && ! -L "$export_options_plist" ]] ||
  fail "pass an absolute export options plist"
[[ -n "$output_directory" && "$output_directory" == /* &&
   ! -e "$output_directory" && ! -L "$output_directory" ]] ||
  fail "pass an absolute, new export output directory"
output_parent="$(dirname "$output_directory")"
[[ -d "$output_parent" && "$(basename "$output_directory")" != "." &&
   "$(basename "$output_directory")" != ".." && ! -L "$output_parent" ]] ||
  fail "export output parent must already exist"

"$script_dir/verify-app2-release-package.sh" "$archive_path"

staging_template="$output_parent/.wenxintong-app2-export-stage.XXXXXXXX"
staging_root="$(mktemp -d "$staging_template")" ||
  fail "cannot create the isolated export staging directory"
cleanup() {
  if [[ -n "${staging_root:-}" && "$staging_root" == "$output_parent"/.wenxintong-app2-export-stage.* &&
        -d "$staging_root" && ! -L "$staging_root" ]]; then
    rm -rf -- "$staging_root"
  fi
}
trap cleanup EXIT
staging_export="$staging_root/xcode-export"
mkdir -m 700 "$staging_export"

xcodebuild -exportArchive \
  -archivePath "$archive_path" \
  -exportOptionsPlist "$export_options_plist" \
  -exportPath "$staging_export"

ipa_files=()
while IFS= read -r -d '' candidate; do
  ipa_files+=("$candidate")
done < <(find "$staging_export" -maxdepth 1 -mindepth 1 -iname '*.ipa' -print0)
[[ "${#ipa_files[@]}" -eq 1 ]] ||
  fail "export must produce exactly one top-level IPA"
[[ -f "${ipa_files[0]}" && ! -L "${ipa_files[0]}" ]] ||
  fail "the single exported IPA must be a regular non-symlink file"

"$script_dir/verify-app2-ipa.sh" \
  "${ipa_files[0]}" \
  "$archive_path" \
  "$output_directory"
printf 'PASS: verified APP2 IPA exported to %s\n' "$output_directory"
}

export_app2_release_main() {
  local archive_path="${1:-}"
  local export_options_plist="${2:-}"
  local output_directory="${3:-}"
  [[ -n "$archive_path" && "$archive_path" == /* &&
     -d "$archive_path" && ! -L "$archive_path" ]] ||
    fail "pass the final absolute APP2 xcarchive path"
  [[ -n "$export_options_plist" && "$export_options_plist" == /* &&
     -f "$export_options_plist" && ! -L "$export_options_plist" ]] ||
    fail "pass an absolute export options plist"
  [[ -n "$output_directory" && "$output_directory" == /* &&
     ! -e "$output_directory" && ! -L "$output_directory" ]] ||
    fail "pass an absolute, new export output directory"
  exec python3 "$snapshot_helper" exec archive "$archive_path" -- \
    bash -c 'source "$1"; export_app2_release_snapshot "$2" "$3" "$4"' \
    app2-fixed-export "$0" "{snapshot}" \
    "$export_options_plist" "$output_directory"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  export_app2_release_main "$@"
fi
