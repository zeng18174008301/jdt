#!/usr/bin/env bash
set -euo pipefail

fail() {
  printf 'Simulator carrier blocked: %s\n' "$1" >&2
  exit 1
}

[[ $# -eq 1 ]] || fail "pass one .app directory"

app_path="$1"
[[ "$app_path" == /* && "$app_path" == *.app ]] ||
  fail "app path must be an absolute .app directory"
[[ -d "$app_path" && ! -L "$app_path" ]] ||
  fail "app path must be an existing non-linked directory"

codesign_tool="${CODESIGN_TOOL:-/usr/bin/codesign}"
[[ -x "$codesign_tool" ]] || fail "codesign tool is unavailable"

"$codesign_tool" --verify --strict "$app_path" >/dev/null 2>&1 ||
  fail "app is not signed"

APP_PATH="$app_path" CODESIGN_TOOL="$codesign_tool" OTOOL_TOOL="${OTOOL_TOOL:-/usr/bin/otool}" python3 - <<'PY' ||
import os
from pathlib import Path
import plistlib
import subprocess

app = Path(os.environ["APP_PATH"])
codesign = os.environ["CODESIGN_TOOL"]
otool = os.environ["OTOOL_TOOL"]

payloads = []
signed = subprocess.run(
    [codesign, "-d", "--entitlements", ":-", str(app)],
    capture_output=True,
)
if signed.stdout:
    try:
        payloads.append(plistlib.loads(signed.stdout))
    except Exception:
        pass

try:
    info = plistlib.loads((app / "Info.plist").read_bytes())
    executable = app / info["CFBundleExecutable"]
    embedded = subprocess.run(
        [otool, "-s", "__TEXT", "__entitlements", "-X", str(executable)],
        check=True,
        capture_output=True,
        text=True,
    ).stdout
    raw = bytearray()
    for line in embedded.splitlines():
        columns = line.split()
        for word in columns[1:]:
            raw.extend(bytes.fromhex(word)[::-1])
    end = raw.find(b"</plist>")
    if end >= 0:
        payloads.append(plistlib.loads(bytes(raw[: end + len(b"</plist>")])))
except Exception:
    pass

authorized = False
for payload in payloads:
    application_identifier = payload.get("application-identifier")
    groups = payload.get("keychain-access-groups")
    if not isinstance(application_identifier, str) or not application_identifier.strip():
        continue
    if groups is None:
        authorized = True
        break
    if isinstance(groups, list) and application_identifier in groups:
        authorized = True
        break

if not authorized:
    raise SystemExit("application-identifier is missing")
PY
  fail "app lacks protected Keychain authority"

printf 'PASS: simulator carrier is signed for protected Keychain access\n'
