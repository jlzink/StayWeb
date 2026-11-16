#!/usr/bin/env bash
set -Eeuo pipefail

if [[ "$(uname -s)" != Darwin ]]; then
    printf '%s\n' 'Run this script on the Mac with Xcode installed.' >&2
    exit 1
fi
STAYWEB_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$STAYWEB_ROOT"
STAYWEB_BUILD_DIR="$STAYWEB_ROOT/build/local/$(date -u +%Y%m%d-%H%M%SZ)"
mkdir -p "$STAYWEB_BUILD_DIR"
exec > >(tee "$STAYWEB_BUILD_DIR/build.log") 2>&1

xcodebuild -version
python3 scripts/prepare_filters.py
python3 scripts/validate.py
python3 scripts/verify_kiosk_metadata.py
node scripts/test_prime_filter.js
STAYWEB_SIMULATOR_ID="$(python3 scripts/select_simulator.py --family ipad)"
xcrun simctl bootstatus "$STAYWEB_SIMULATOR_ID" -b
xcodebuild test -project StayWeb.xcodeproj -scheme StayWeb -configuration Debug \
    -destination "platform=iOS Simulator,id=$STAYWEB_SIMULATOR_ID" \
    -derivedDataPath "$STAYWEB_BUILD_DIR/Simulator" \
    -resultBundlePath "$STAYWEB_BUILD_DIR/Tests.xcresult" CODE_SIGNING_ALLOWED=NO
python3 scripts/verify_kiosk_metadata.py "$STAYWEB_BUILD_DIR/Simulator/Build/Products/Debug-iphonesimulator/StayWeb.app"
xcodebuild build -project StayWeb.xcodeproj -scheme StayWeb -configuration Release \
    -sdk iphoneos -destination 'generic/platform=iOS' \
    -derivedDataPath "$STAYWEB_BUILD_DIR/Device" CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO
python3 scripts/verify_kiosk_metadata.py "$STAYWEB_BUILD_DIR/Device/Build/Products/Release-iphoneos/StayWeb.app"
printf 'Build and tests completed. Logs: %s\n' "$STAYWEB_BUILD_DIR/build.log"
printf '%s\n' 'Open StayWeb.xcodeproj, retain the existing bundle ID/signing identity, and run on your iPad to validate the OS kiosk lock.'
