#!/usr/bin/env bash
set -euo pipefail

fail() {
  printf 'Codemagic APNs setup blocked: %s\n' "$1" >&2
  exit 1
}

bundle_id="${BUNDLE_ID:-}"
app_name="${APP_NAME:-BlueStoneIM}"
bundle_id_name="${APPLE_BUNDLE_ID_NAME:-$app_name}"
bundle_id_resource_id="${APPLE_BUNDLE_ID_RESOURCE_ID:-}"

[[ -n "$bundle_id" ]] || fail "BUNDLE_ID is required"

extract_bundle_id_resource_id() {
  local json_path="${1:?}"
  python3 - "$bundle_id" "$json_path" <<'PY'
import json
import sys

bundle_id = sys.argv[1]
json_path = sys.argv[2]


def walk(value):
    if isinstance(value, dict):
        yield value
        for nested in value.values():
            yield from walk(nested)
    elif isinstance(value, list):
        for nested in value:
            yield from walk(nested)


with open(json_path, "r", encoding="utf-8") as handle:
    payload = json.load(handle)
for item in walk(payload):
    attributes = item.get("attributes", {})
    if not isinstance(attributes, dict):
        attributes = {}
    identifier = (
        item.get("identifier")
        or item.get("bundleId")
        or item.get("bundle_id")
        or attributes.get("identifier")
    )
    resource_id = item.get("id")
    if identifier == bundle_id and isinstance(resource_id, str) and resource_id:
        print(resource_id)
        raise SystemExit(0)
raise SystemExit(1)
PY
}

verify_push_capability() {
  local json_path="${1:?}"
  python3 - "$json_path" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as handle:
    payload = json.load(handle)
text = json.dumps(payload, sort_keys=True)
if "Push Notifications" in text or "PUSH_NOTIFICATIONS" in text:
    raise SystemExit(0)
raise SystemExit("Push Notifications capability is not enabled")
PY
}

if [[ -z "$bundle_id_resource_id" ]]; then
  list_json="$(mktemp)"
  app-store-connect bundle-ids list \
    --bundle-id-identifier "$bundle_id" \
    --platform IOS \
    --strict-match-identifier \
    --json >"$list_json"

  if ! bundle_id_resource_id="$(extract_bundle_id_resource_id "$list_json")"; then
    create_json="$(mktemp)"
    app-store-connect bundle-ids create "$bundle_id" \
      --name "$bundle_id_name" \
      --platform IOS \
      --json >"$create_json"
    bundle_id_resource_id="$(extract_bundle_id_resource_id "$create_json")"
  fi
fi

if ! app-store-connect bundle-ids enable-capabilities "$bundle_id_resource_id" \
  --capability "Push Notifications"
then
  printf 'Push capability enable command did not complete; checking current capability state.\n'
fi

capabilities_json="$(mktemp)"
app-store-connect bundle-ids capabilities "$bundle_id_resource_id" --json \
  >"$capabilities_json"
verify_push_capability "$capabilities_json"

printf 'PASS: Push Notifications capability is enabled for %s.\n' "$bundle_id"
