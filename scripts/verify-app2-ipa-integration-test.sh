#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/wenxintong-app2-verify-integration.XXXXXX")"
trap 'rm -rf "$temp_dir"' EXIT

fail() {
  printf 'APP2 IPA verifier integration test failed: %s\n' "$1" >&2
  exit 1
}

mkdir -p \
  "$temp_dir/scripts" \
  "$temp_dir/runtime" \
  "$temp_dir/archive.xcarchive/Products/Applications/WenxintongApp2.app"
cp \
  "$script_dir/verify-app2-ipa.sh" \
  "$script_dir/app2-ipa-safe-extract.py" \
  "$script_dir/app2_filesystem_snapshot.py" \
  "$temp_dir/scripts/"

cat >"$temp_dir/scripts/verify-app2-release-package.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
exit 0
SH
cat >"$temp_dir/scripts/verify-app2-archive.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
exit 0
SH
cat >"$temp_dir/scripts/app2-app-payload-evidence.py" <<'PY'
#!/usr/bin/env python3
import json
import os
import time

if os.environ.get("FAKE_PAYLOAD_SLEEP") == "YES":
    time.sleep(1)
print(json.dumps({"schema_version": 1, "signed_bundles": [{"relative_path": "."}]}))
PY
chmod 700 "$temp_dir/scripts/"*

python3 - "$temp_dir" <<'PY'
import json
import plistlib
import stat
import sys
import zipfile
from pathlib import Path

root = Path(sys.argv[1])
archive = root / "archive.xcarchive"
app = archive / "Products/Applications/WenxintongApp2.app"
info = plistlib.dumps(
    {
        "CFBundleIdentifier": "com.wenxintong.app2",
        "CFBundleExecutable": "WenxintongApp2",
    },
    fmt=plistlib.FMT_BINARY,
    sort_keys=True,
)
(app / "Info.plist").write_bytes(info)
digest = "0" * 64
(archive / "APP2_RELEASE_ATTESTATION.json").write_text(
    json.dumps(
        {
            "schema_version": 5,
            "archive_payload_sha256": digest,
            "approved_archive_payload_sha256": digest,
            "candidate_evidence_sha256": digest,
            "approval_manifest_sha256": digest,
        }
    ),
    encoding="utf-8",
)
with zipfile.ZipFile(root / "source.ipa", "w") as ipa:
    ipa.writestr("Payload/WenxintongApp2.app/Info.plist", info)
    executable = zipfile.ZipInfo(
        "Payload/WenxintongApp2.app/WenxintongApp2"
    )
    executable.external_attr = (stat.S_IFREG | 0o755) << 16
    ipa.writestr(executable, b"approved-executable")
PY

TMPDIR="$temp_dir/runtime" \
  "$temp_dir/scripts/verify-app2-ipa.sh" \
  "$temp_dir/source.ipa" \
  "$temp_dir/archive.xcarchive" \
  "$temp_dir/baseline" \
  >"$temp_dir/baseline.log"
python3 - "$temp_dir/baseline" <<'PY'
import hashlib
import json
import sys
from pathlib import Path

root = Path(sys.argv[1])
evidence = json.loads(
    (root / "APP2_IPA_VERIFICATION.json").read_text(encoding="utf-8")
)
delivered = hashlib.sha256((root / "WenxintongApp2.ipa").read_bytes()).hexdigest()
assert evidence["ipa_sha256"] == delivered
PY

python3 - "$temp_dir/runtime" <<'PY' &
import os
import sys
import time
from pathlib import Path

root = Path(sys.argv[1])
deadline = time.time() + 10
while time.time() < deadline:
    for sealed in root.glob("wenxintong-app2-ipa.*/sealed.ipa"):
        if sealed.is_file() and sealed.stat().st_size > 0:
            replacement = sealed.parent / "replacement.ipa"
            replacement.write_bytes(b"unverified-replacement")
            os.replace(replacement, sealed)
            (root / "sealed-replaced").write_text("yes", encoding="utf-8")
            raise SystemExit(0)
    time.sleep(0.001)
raise SystemExit(2)
PY
watcher_pid=$!
if TMPDIR="$temp_dir/runtime" FAKE_PAYLOAD_SLEEP=YES \
  "$temp_dir/scripts/verify-app2-ipa.sh" \
  "$temp_dir/source.ipa" \
  "$temp_dir/archive.xcarchive" \
  "$temp_dir/race" \
  >"$temp_dir/race.log" 2>&1; then
  fail "sealed IPA pathname replacement unexpectedly passed real verifier"
fi
wait "$watcher_pid" ||
  fail "sealed IPA replacement watcher did not execute"
[[ -f "$temp_dir/runtime/sealed-replaced" &&
   ! -e "$temp_dir/race" ]] ||
  fail "sealed IPA replacement failure left deliverable output"

printf 'PASS: real APP2 IPA verifier integrates with the sealed extractor and rejects sealed-path replacement before delivery.\n'
