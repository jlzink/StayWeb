#!/usr/bin/env bash
set -Eeuo pipefail

if [[ "$(uname -s)" != Darwin ]]; then
    printf '%s\n' 'Run this script locally on the MacBook Pro with full Xcode installed.' >&2
    exit 1
fi

STAYWEB_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$STAYWEB_ROOT"
mkdir -p "$STAYWEB_ROOT/build/local"
STAYWEB_BUILD_DIR="$(mktemp -d "$STAYWEB_ROOT/build/local/$(date -u +%Y%m%d-%H%M%SZ).XXXXXX")"
STAYWEB_STEP='Checking local prerequisites'
exec > >(tee "$STAYWEB_BUILD_DIR/build.log") 2>&1

stayweb_failure() {
    local stayweb_status=$?
    trap - ERR
    printf '\nFAILED: %s (exit %s).\n' "$STAYWEB_STEP" "$stayweb_status" >&2
    printf 'Full log: %s\n' "$STAYWEB_BUILD_DIR/build.log" >&2
    printf 'Any completed Xcode result bundles are in: %s\n' "$STAYWEB_BUILD_DIR" >&2
    exit "$stayweb_status"
}
trap stayweb_failure ERR

stayweb_stop() {
    printf '\n%s\n' "$1" >&2
    printf 'Full log: %s\n' "$STAYWEB_BUILD_DIR/build.log" >&2
    exit 1
}

for stayweb_command in xcodebuild xcrun python3; do
    if ! command -v "$stayweb_command" >/dev/null 2>&1; then
        stayweb_stop "Missing $stayweb_command. Install/open full Xcode and its required components before building. Python 3 must also be available as python3."
    fi
done
if ! xcodebuild -version; then
    stayweb_stop 'Full Xcode is not selected or ready. Open Xcode once and finish its setup. If needed, set DEVELOPER_DIR to your Xcode.app/Contents/Developer directory for this command; this script does not change your system selection.'
fi
if ! xcodebuild -checkFirstLaunchStatus; then
    stayweb_stop 'Open Xcode and finish its first-launch setup and required components, then rerun this script.'
fi
STAYWEB_DEVICE_SDK="$(xcrun --sdk iphoneos --show-sdk-version)"
python3 - "$STAYWEB_DEVICE_SDK" <<'PY'
import re
import sys
value = sys.argv[1]
match = re.match(r'^(\d+)\.(\d+)', value)
if not match or tuple(map(int, match.groups())) < (18, 4):
    raise SystemExit('The selected Xcode needs an iOS 18.4 or newer SDK (Xcode 16.3 or newer). Select a newer full Xcode and retry.')
print(f'Local iOS SDK: {value}; guest kiosk APIs require 18.4 or newer.')
PY

# Fail early if the iPad simulator needed for the kiosk tests is not installed.
# Do not fall back to an older runtime that would silently skip guest tests.
STAYWEB_STEP='Selecting an iPad simulator with iOS 18.4 or newer'
STAYWEB_SIMULATOR_ID="$(python3 scripts/select_simulator.py --family ipad --minimum-os 18.4)"

STAYWEB_STEP='Preparing the local ad-filter snapshot'
python3 scripts/prepare_filters.py
STAYWEB_STEP='Validating source resources and kiosk metadata'
python3 scripts/validate.py
python3 scripts/verify_kiosk_metadata.py

# Node is only for optional JavaScript fixtures, not a native build dependency.
STAYWEB_JS_STATUS='SKIPPED (Node.js 18+ with Request/Response globals is not available)'
if command -v node >/dev/null 2>&1 && node -e 'process.exit(typeof Request === "function" && typeof Response === "function" ? 0 : 1)' >/dev/null 2>&1; then
    STAYWEB_STEP='Running optional JavaScript filter fixtures locally'
    node scripts/test_prime_filter.js
    STAYWEB_JS_STATUS='PASSED'
else
    printf '%s\n' 'Skipping optional Node.js filter fixtures. Native XCTest and WebKit tests will still run.'
fi

STAYWEB_STEP='Booting the selected local iPad simulator'
xcrun simctl bootstatus "$STAYWEB_SIMULATOR_ID" -b
STAYWEB_STEP='Compiling and testing in the local iPad simulator'
xcodebuild test -project StayWeb.xcodeproj -scheme StayWeb -configuration Debug \
    -destination "platform=iOS Simulator,id=$STAYWEB_SIMULATOR_ID" \
    -derivedDataPath "$STAYWEB_BUILD_DIR/Simulator" \
    -resultBundlePath "$STAYWEB_BUILD_DIR/Tests.xcresult" CODE_SIGNING_ALLOWED=NO
python3 scripts/verify_kiosk_metadata.py "$STAYWEB_BUILD_DIR/Simulator/Build/Products/Debug-iphonesimulator/StayWeb.app"

STAYWEB_STEP='Compiling the local physical-device build without signing'
xcodebuild build -project StayWeb.xcodeproj -scheme StayWeb -configuration Release \
    -sdk iphoneos -destination 'generic/platform=iOS' \
    -derivedDataPath "$STAYWEB_BUILD_DIR/Device" \
    -resultBundlePath "$STAYWEB_BUILD_DIR/DeviceBuild.xcresult" \
    CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO
python3 scripts/verify_kiosk_metadata.py "$STAYWEB_BUILD_DIR/Device/Build/Products/Release-iphoneos/StayWeb.app"

printf '\nNative build and simulator tests completed locally.\n'
printf 'Optional JavaScript fixtures: %s\n' "$STAYWEB_JS_STATUS"
printf 'Full log: %s\n' "$STAYWEB_BUILD_DIR/build.log"
printf 'Simulator results: %s\n' "$STAYWEB_BUILD_DIR/Tests.xcresult"
printf 'Device compile results: %s\n' "$STAYWEB_BUILD_DIR/DeviceBuild.xcresult"
printf '%s\n' 'The device build above is unsigned. This script does not regenerate the project or change your saved bundle ID, developer team, or signing settings.'
printf '%s\n' 'Open StayWeb.xcodeproj, choose your developer team in Signing & Capabilities, and run on your iPad to validate the actual OS kiosk lock. See README.md for first-account setup.'
