#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PROJECT="$APP_DIR/BlueStoneIM.xcodeproj"
SCHEME="BlueStoneIM-InternalValidation"
CONFIGURATION="Release"
RUN_ID="${RUN_ID:-$(date +%Y%m%d-%H%M%S)}"
OUTPUT_DIR="${OUTPUT_DIR:-$APP_DIR/build/internal-validation-$RUN_ID}"
ARCHIVE_PATH="${ARCHIVE_PATH:-$OUTPUT_DIR/BlueStoneIM-internal-validation.xcarchive}"
EXPORT_PATH="${EXPORT_PATH:-$OUTPUT_DIR/export}"
EXPORT_OPTIONS_PLIST="${EXPORT_OPTIONS_PLIST:-}"
# The floating access-diagnostics capability and marker are present in every
# formal and internal build. This internal route keeps the legacy Swift
# condition only for additional internal-only trace collectors; it is not an
# authorization mechanism and does not control whether the overlay exists.

REPO_ROOT="$(git -C "$APP_DIR" rev-parse --show-toplevel)"
HEAD_COMMIT="$(git -C "$REPO_ROOT" rev-parse HEAD)"
REQUESTED_SOURCE_COMMIT="${SOURCE_COMMIT:-$HEAD_COMMIT}"
if [[ ! "$REQUESTED_SOURCE_COMMIT" =~ ^[0-9a-fA-F]{7,64}$ ]]; then
  echo "SOURCE_COMMIT must be a 7-64 character hexadecimal Git identity" >&2
  exit 1
fi
if ! SOURCE_COMMIT="$(git -C "$REPO_ROOT" rev-parse --verify "${REQUESTED_SOURCE_COMMIT}^{commit}" 2>/dev/null)" \
  || [[ "$SOURCE_COMMIT" != "$HEAD_COMMIT" ]]; then
  echo "SOURCE_COMMIT must resolve to the current tracked HEAD" >&2
  exit 1
fi
if ! git -C "$REPO_ROOT" diff --quiet -- \
  || ! git -C "$REPO_ROOT" diff --cached --quiet --; then
  echo "Internal validation archives require a clean tracked HEAD and index" >&2
  exit 1
fi

BUILD_IDENTITY="${BUILD_IDENTITY:-internal-validation-$RUN_ID-${SOURCE_COMMIT:0:12}}"
if [[ ! "$BUILD_IDENTITY" =~ ^[A-Za-z0-9._:-]{1,128}$ ]]; then
  echo "BUILD_IDENTITY must use 1-128 safe identity characters" >&2
  exit 1
fi

mkdir -p "$OUTPUT_DIR"
INTERNAL_INFO_DIR="$(mktemp -d "$OUTPUT_DIR/.internal-info.XXXXXXXX")"
cleanup() {
  if [[ -n "${INTERNAL_INFO_DIR:-}" && "$INTERNAL_INFO_DIR" == "$OUTPUT_DIR"/.internal-info.* &&
        -d "$INTERNAL_INFO_DIR" && ! -L "$INTERNAL_INFO_DIR" ]]; then
    rm -rf -- "$INTERNAL_INFO_DIR"
  fi
}
trap cleanup EXIT
INTERNAL_INFO_PLIST="$INTERNAL_INFO_DIR/Info.plist"
cp "$APP_DIR/BlueStoneIM/Info.plist" "$INTERNAL_INFO_PLIST"
/usr/libexec/PlistBuddy \
  -c 'Set :WXTAccessDiagnosticsOverlayCompiled YES' \
  "$INTERNAL_INFO_PLIST"

echo "Archiving $SCHEME ($CONFIGURATION) for internal validation..."
echo "Access diagnostics overlay: compiled in, hidden until current-policy authorizes five logo taps"
echo "Source commit: $SOURCE_COMMIT"
echo "Build identity: $BUILD_IDENTITY"
echo "Archive path: $ARCHIVE_PATH"

xcodebuild archive \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -destination 'generic/platform=iOS' \
  -archivePath "$ARCHIVE_PATH" \
  'OTHER_SWIFT_FLAGS=$(inherited) -DACCESS_DIAGNOSTICS_OVERLAY_ENABLED' \
  INFOPLIST_FILE="$INTERNAL_INFO_PLIST" \
  WXT_FORMAL_BUILD=NO \
  WXT_SOURCE_COMMIT="$SOURCE_COMMIT" \
  WXT_BUILD_IDENTITY="$BUILD_IDENTITY"

ARCHIVE_INFO_PLIST="$ARCHIVE_PATH/Products/Applications/BlueStoneIM.app/Info.plist"
if [[ ! -f "$ARCHIVE_INFO_PLIST" ]]; then
  echo "Archived app Info.plist was not found" >&2
  exit 1
fi
if [[ "$(/usr/libexec/PlistBuddy -c 'Print :WXTFormalBuild' "$ARCHIVE_INFO_PLIST")" != "NO" ]] \
  || [[ "$(/usr/libexec/PlistBuddy -c 'Print :WXTAccessDiagnosticsOverlayCompiled' "$ARCHIVE_INFO_PLIST")" != "YES" ]] \
  || [[ "$(/usr/libexec/PlistBuddy -c 'Print :WXTSourceCommit' "$ARCHIVE_INFO_PLIST")" != "$SOURCE_COMMIT" ]] \
  || [[ "$(/usr/libexec/PlistBuddy -c 'Print :WXTBuildIdentity' "$ARCHIVE_INFO_PLIST")" != "$BUILD_IDENTITY" ]]; then
  echo "Archived app build policy or source identity readback did not match" >&2
  exit 1
fi

if [[ -n "$EXPORT_OPTIONS_PLIST" ]]; then
  if [[ ! -f "$EXPORT_OPTIONS_PLIST" ]]; then
    echo "EXPORT_OPTIONS_PLIST not found: $EXPORT_OPTIONS_PLIST" >&2
    exit 1
  fi
  mkdir -p "$EXPORT_PATH"
  echo "Exporting IPA..."
  xcodebuild -exportArchive \
    -archivePath "$ARCHIVE_PATH" \
    -exportOptionsPlist "$EXPORT_OPTIONS_PLIST" \
    -exportPath "$EXPORT_PATH"
  IPA_PATH="$(find "$EXPORT_PATH" -maxdepth 1 -name '*.ipa' -print -quit)"
  if [[ -n "$IPA_PATH" ]]; then
    echo "IPA: $IPA_PATH"
  else
    echo "Export finished but no IPA was found in $EXPORT_PATH" >&2
    exit 1
  fi
else
  echo "Archive created. Set EXPORT_OPTIONS_PLIST=/path/to/ExportOptions.plist to export an IPA."
fi

cat <<EOF

Internal validation package rule:
- Access diagnostics overlay code and marker are present in formal APP1, formal APP2, and internal-validation builds.
- The legacy ACCESS_DIAGNOSTICS_OVERLAY_ENABLED condition enables only additional internal trace collectors; it cannot authorize the overlay.
- The dedicated $SCHEME archive action verifies this artifact in internal-validation mode; formal APP1/APP2 routes independently require the same capability marker.
- The app bundle records source commit "$SOURCE_COMMIT" and build identity "$BUILD_IDENTITY".
- The access diagnostics overlay stays hidden until current-policy allows the effective AppId and the allowed Logo is tapped five times in three seconds.
- Do not use this script for normal App Store production builds unless explicitly requested.
EOF
