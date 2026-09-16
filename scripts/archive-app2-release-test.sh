#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/wenxintong-app2-archive-test.XXXXXX")"
trap 'rm -rf "$temp_dir"' EXIT

fail() {
  printf 'APP2 archive entrypoint test failed: %s\n' "$1" >&2
  exit 1
}

mkdir -p "$temp_dir/scripts" "$temp_dir/bin" "$temp_dir/runtime"
cp "$script_dir/archive-app2-release.sh" "$temp_dir/scripts/archive-app2-release.sh"
cp "$script_dir/app2_filesystem_snapshot.py" "$temp_dir/scripts/app2_filesystem_snapshot.py"
cat >"$temp_dir/scripts/verify-app2-archive.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
[[ -d "$1" ]]
printf 'verify\n' >>"${FAKE_FLOW_LOG:?}"
SH
cat >"$temp_dir/scripts/app2-release-attestation.py" <<'PY'
#!/usr/bin/env python3
import os
import sys
from pathlib import Path

if len(sys.argv) != 3 or sys.argv[1] not in {
    "candidate-snapshot",
    "verify-candidate-snapshot",
    "finalize-snapshot",
}:
    raise SystemExit(2)
with Path(os.environ["FAKE_FLOW_LOG"]).open("a", encoding="utf-8") as handle:
    handle.write(sys.argv[1] + "\n")
PY
cat >"$temp_dir/scripts/verify-app2-release-package.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf 'package\n' >>"${FAKE_FLOW_LOG:?}"
SH
cat >"$temp_dir/bin/xcodebuild" <<'SH'
#!/usr/bin/env bash
set -euo pipefail

if [[ " $* " == *" -showBuildSettings "* ]]; then
  printf '    OTHER_SWIFT_FLAGS = %s\n' "${FAKE_OTHER_SWIFT_FLAGS:-}"
  printf '    SWIFT_ACTIVE_COMPILATION_CONDITIONS = %s\n' \
    "${FAKE_SWIFT_CONDITIONS:-APP_VARIANT_APP2}"
  exit 0
fi
archive_path=""
while [[ "$#" -gt 0 ]]; do
  if [[ "$1" == "-archivePath" ]]; then
    archive_path="$2"
    shift 2
    continue
  fi
  shift
done
[[ -n "$archive_path" ]] || exit 2
mkdir -p "$archive_path/Products/Applications/WenxintongApp2.app"
printf 'archive\n' >>"${FAKE_FLOW_LOG:?}"
SH
chmod 700 \
  "$temp_dir/scripts/archive-app2-release.sh" \
  "$temp_dir/scripts/app2_filesystem_snapshot.py" \
  "$temp_dir/scripts/verify-app2-archive.sh" \
  "$temp_dir/scripts/app2-release-attestation.py" \
  "$temp_dir/scripts/verify-app2-release-package.sh" \
  "$temp_dir/bin/xcodebuild"

run_archive() {
  local mode="$1"
  local output="$2"
  local final_output="${3:-}"
  PATH="$temp_dir/bin:$PATH" \
    TMPDIR="$temp_dir/runtime" \
    FAKE_FLOW_LOG="$temp_dir/flow.log" \
    "$temp_dir/scripts/archive-app2-release.sh" "$mode" "$output" ${final_output:+"$final_output"}
}

for mode in flags conditions; do
  output="$temp_dir/$mode.xcarchive"
  case "$mode" in
    flags)
      if FAKE_OTHER_SWIFT_FLAGS="-DACCESS_DIAGNOSTICS_OVERLAY_ENABLED" \
        run_archive candidate "$output" >"$temp_dir/$mode.log" 2>&1; then
        fail "inherited diagnostics Swift flag unexpectedly passed"
      fi
      ;;
    conditions)
      if FAKE_SWIFT_CONDITIONS="APP_VARIANT_APP2 ACCESS_DIAGNOSTICS_OVERLAY_ENABLED" \
        run_archive candidate "$output" >"$temp_dir/$mode.log" 2>&1; then
        fail "extra diagnostics compilation condition unexpectedly passed"
      fi
      ;;
  esac
  [[ ! -e "$output" ]] ||
    fail "invalid effective settings still invoked archive creation"
done

mkdir "$temp_dir/existing-candidate.xcarchive"
printf 'concurrent-owner\n' >"$temp_dir/existing-candidate.xcarchive/owner"
if run_archive candidate "$temp_dir/existing-candidate.xcarchive" \
  >"$temp_dir/existing-candidate.log" 2>&1; then
  fail "candidate overwrote a pre-existing output directory"
fi
[[ "$(cat "$temp_dir/existing-candidate.xcarchive/owner")" == "concurrent-owner" ]] ||
  fail "candidate altered a pre-existing output directory"

mkdir -p "$temp_dir/forged.xcarchive/Products/Applications/WenxintongApp2.app"
forged_fd=9
exec 9<"$temp_dir/forged.xcarchive"
read -r forged_dev forged_ino < <(
  python3 - "$forged_fd" <<'PY'
import os
import sys

state = os.fstat(int(sys.argv[1]))
print(state.st_dev, state.st_ino)
PY
)
if APP2_INTERNAL_SEALED_WORKFLOW=YES \
  APP2_SEALED_SNAPSHOT="$temp_dir/forged.xcarchive" \
  APP2_SEALED_SNAPSHOT_FD="$forged_fd" \
  APP2_SEALED_SNAPSHOT_DEV="$forged_dev" \
  APP2_SEALED_SNAPSHOT_INO="$forged_ino" \
  "$temp_dir/scripts/archive-app2-release.sh" \
  candidate-sealed \
  "$temp_dir/forged.xcarchive" \
  >"$temp_dir/forged.log" 2>&1; then
  fail "caller-forged valid descriptor/internal workflow unexpectedly passed"
fi
exec 9<&-

: >"$temp_dir/flow.log"
run_archive candidate "$temp_dir/success.xcarchive" >"$temp_dir/candidate.log"
[[ "$(cat "$temp_dir/flow.log")" == $'archive\ncandidate-snapshot\nverify\nverify-candidate-snapshot' ]] ||
  fail "candidate build performed approval or packaging steps"
run_archive finalize \
  "$temp_dir/success.xcarchive" \
  "$temp_dir/final.xcarchive" >"$temp_dir/finalize.log"
[[ "$(cat "$temp_dir/flow.log")" == $'archive\ncandidate-snapshot\nverify\nverify-candidate-snapshot\nverify\nfinalize-snapshot\npackage' ]] ||
  fail "candidate, approval verification and finalization order drifted"
[[ -d "$temp_dir/success.xcarchive" && -d "$temp_dir/final.xcarchive" ]] ||
  fail "finalization did not preserve the candidate and create a distinct final archive"

python3 - "$temp_dir/success.xcarchive/A-large.bin" <<'PY'
import sys
from pathlib import Path

Path(sys.argv[1]).write_bytes(b"x" * (32 * 1024 * 1024))
PY
python3 - "$temp_dir/runtime" "$temp_dir/success.xcarchive" <<'PY' &
import sys
import time
from pathlib import Path

runtime = Path(sys.argv[1])
source = Path(sys.argv[2])
deadline = time.time() + 10
while time.time() < deadline:
    for copied in runtime.glob(".wenxintong-app2-sealed.*/tree/A-large.bin"):
        if copied.is_file() and copied.stat().st_size > 1024 * 1024:
            (source / "ZZ-concurrent-mutation").write_text(
                "changed-after-source-enumeration",
                encoding="utf-8",
            )
            (runtime / "finalize-race-executed").write_text("yes", encoding="utf-8")
            raise SystemExit(0)
    time.sleep(0.001)
raise SystemExit(2)
PY
race_pid=$!
if run_archive finalize \
  "$temp_dir/success.xcarchive" \
  "$temp_dir/racing-final.xcarchive" \
  >"$temp_dir/racing-final.log" 2>&1; then
  fail "concurrently changed candidate unexpectedly finalized"
fi
wait "$race_pid" ||
  fail "candidate mutation watcher did not execute"
[[ -f "$temp_dir/runtime/finalize-race-executed" &&
   ! -e "$temp_dir/racing-final.xcarchive" ]] ||
  fail "failed concurrent finalization left a promoted target"

printf 'PASS: APP2 archive entrypoint resolves effective settings and keeps candidate/finalize ordering fail-closed.\n'
