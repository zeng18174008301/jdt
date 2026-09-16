#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
snapshot_helper="$script_dir/app2_filesystem_snapshot.py"

fail() {
  printf 'APP2 release package blocked: %s\n' "$1" >&2
  exit 1
}

verify_app2_release_package_snapshot() {
  local archive_path="${1:-}"
  local app_path="$archive_path/Products/Applications/WenxintongApp2.app"
  [[ -n "$archive_path" && "$archive_path" == /* && -d "$archive_path" ]] ||
    fail "pass the final absolute APP2 xcarchive path"
  "$script_dir/verify-app2-archive.sh" "$app_path"
  python3 "$script_dir/app2-release-attestation.py" verify-snapshot "$archive_path"
  printf 'PASS: APP2 release archive and fixed attestation match.\n'
}

verify_app2_release_package_main() {
  local archive_path="${1:-}"
  [[ -n "$archive_path" && "$archive_path" == /* && -d "$archive_path" ]] ||
    fail "pass the final absolute APP2 xcarchive path"
  exec python3 "$snapshot_helper" exec archive "$archive_path" -- \
    bash -c 'source "$1"; verify_app2_release_package_snapshot "$2"' \
    app2-fixed-package-verifier "$0" "{snapshot}"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  verify_app2_release_package_main "$@"
fi
