#!/bin/sh

set -eu

PROJECT="CalendarMCPHelperApp/CalendarMCPHelperApp.xcodeproj"
SCHEME="CalendarMCPHelperApp"
DERIVED_DATA="CalendarMCPHelperApp/build"
APP_PATH="$DERIVED_DATA/Build/Products/Release/CalendarMCPHelperApp.app"

detect_identity() {
  security find-identity -v -p codesigning | awk -F'"' '/Apple Development/ { print $2; exit }'
}

CODESIGN_IDENTITY="${CALENDAR_MCP_CODESIGN_IDENTITY:-$(detect_identity)}"

if [ -z "$CODESIGN_IDENTITY" ]; then
  echo "No Apple Development signing identity was found. Install one in Keychain or set CALENDAR_MCP_CODESIGN_IDENTITY." >&2
  exit 1
fi

xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration Release \
  -derivedDataPath "$DERIVED_DATA" \
  CODE_SIGNING_ALLOWED=NO

codesign \
  --force \
  --deep \
  --options runtime \
  --timestamp=none \
  --sign "$CODESIGN_IDENTITY" \
  "$APP_PATH"

codesign --verify --deep --strict --verbose=2 "$APP_PATH"
