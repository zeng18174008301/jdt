#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
project_dir="$(cd "$script_dir/.." && pwd)"
verify_archive="$script_dir/verify-app2-archive.sh"
attestation="$script_dir/app2-release-attestation.py"
verify_package="$script_dir/verify-app2-release-package.sh"
snapshot_helper="$script_dir/app2_filesystem_snapshot.py"

fail() {
  printf 'APP2 release archive blocked: %s\n' "$1" >&2
  exit 1
}

app2_candidate_mutate_snapshot() {
  local snapshot_path="${1:?}"
  python3 "$attestation" candidate-snapshot "$snapshot_path"
}

app2_candidate_verify_snapshot() {
  local snapshot_path="${1:?}"
  APP2_CANDIDATE_BUILD=YES \
    "$verify_archive" "$snapshot_path/Products/Applications/WenxintongApp2.app"
  python3 "$attestation" verify-candidate-snapshot "$snapshot_path"
}

app2_finalize_mutate_snapshot() {
  local snapshot_path="${1:?}"
  "$verify_archive" "$snapshot_path/Products/Applications/WenxintongApp2.app"
  python3 "$attestation" finalize-snapshot "$snapshot_path"
}

app2_finalize_verify_snapshot() {
  local snapshot_path="${1:?}"
  "$verify_package" "$snapshot_path"
}

archive_app2_release_main() {
  local mode="${1:-}"
  local archive_path="${2:-}"
  local final_archive_path="${3:-}"
  [[ "$mode" == "candidate" || "$mode" == "finalize" ]] ||
    fail "usage: archive-app2-release.sh candidate <new-candidate.xcarchive> | finalize <candidate.xcarchive> <new-final.xcarchive>"
  [[ -n "$archive_path" && "$archive_path" == /* && "$archive_path" == *.xcarchive ]] ||
    fail "pass one absolute .xcarchive path"

  if [[ "$mode" == "finalize" ]]; then
    [[ -d "$archive_path" && ! -L "$archive_path" ]] ||
      fail "finalize requires the existing candidate xcarchive"
    [[ -n "$final_archive_path" && "$final_archive_path" == /* &&
       "$final_archive_path" == *.xcarchive &&
       ! -e "$final_archive_path" && ! -L "$final_archive_path" ]] ||
      fail "finalize requires one new absolute finalized xcarchive path"
    python3 "$snapshot_helper" promote-exec archive \
      "$archive_path" \
      "$final_archive_path" \
      --mutate \
      bash -c 'source "$1"; app2_finalize_mutate_snapshot "$2"' \
      app2-fixed-finalize "$0" "{snapshot}" \
      --verify \
      bash -c 'source "$1"; app2_finalize_verify_snapshot "$2"' \
      app2-fixed-finalize "$0" "{snapshot}"
    printf 'PASS: approved APP2 candidate finalized to new archive: %s\n' \
      "$final_archive_path"
    return
  fi

  [[ -z "$final_archive_path" ]] ||
    fail "candidate accepts exactly one output archive path"
  [[ ! -e "$archive_path" && ! -L "$archive_path" ]] ||
    fail "refusing to overwrite an existing archive"
  local archive_parent
  archive_parent="$(dirname "$archive_path")"
  [[ -d "$archive_parent" && ! -L "$archive_parent" ]] ||
    fail "candidate archive parent must exist and must not be linked"

  local -a build_arguments=(
    -project "$project_dir/BlueStoneIM.xcodeproj"
    -scheme BlueStoneIM-App2
    -configuration Release-App2
    OTHER_SWIFT_FLAGS=""
    SWIFT_ACTIVE_COMPILATION_CONDITIONS="APP_VARIANT_APP2"
  )
  local effective_build_settings
  effective_build_settings="$(
    xcodebuild "${build_arguments[@]}" -showBuildSettings
  )" || fail "cannot resolve the effective APP2 Release build settings"
  if ! python3 -c '
import re
import sys

expected = {
    "OTHER_SWIFT_FLAGS": "",
    "SWIFT_ACTIVE_COMPILATION_CONDITIONS": "APP_VARIANT_APP2",
}
observed = {key: set() for key in expected}
pattern = re.compile(
    r"^\s*(OTHER_SWIFT_FLAGS|SWIFT_ACTIVE_COMPILATION_CONDITIONS)\s*=\s*(.*?)\s*$"
)
for line in sys.stdin:
    match = pattern.match(line)
    if match:
        observed[match.group(1)].add(match.group(2))
if any(observed[key] != {value} for key, value in expected.items()):
    raise SystemExit(1)
' <<<"$effective_build_settings"
  then
    fail "effective APP2 Release settings contain inherited diagnostics compilation flags"
  fi

  local staging_root
  staging_root="$(mktemp -d "$archive_parent/.wenxintong-app2-candidate.XXXXXXXX")" ||
    fail "cannot create private APP2 candidate staging"
  cleanup() {
    if [[ -n "${staging_root:-}" && "$staging_root" == "$archive_parent"/.wenxintong-app2-candidate.* &&
          -d "$staging_root" && ! -L "$staging_root" ]]; then
      rm -rf -- "$staging_root"
    fi
  }
  trap cleanup EXIT
  local built_archive="$staging_root/built.xcarchive"

  APP2_CANDIDATE_BUILD=YES xcodebuild archive \
    "${build_arguments[@]}" \
    -archivePath "$built_archive"

  python3 "$snapshot_helper" promote-exec archive \
    "$built_archive" \
    "$archive_path" \
    --mutate \
    bash -c 'source "$1"; app2_candidate_mutate_snapshot "$2"' \
    app2-fixed-candidate "$0" "{snapshot}" \
    --verify \
    bash -c 'source "$1"; app2_candidate_verify_snapshot "$2"' \
    app2-fixed-candidate "$0" "{snapshot}"

  printf 'PASS: APP2 candidate evidence created (not approved or exportable): %s\n' \
    "$archive_path"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  archive_app2_release_main "$@"
fi
