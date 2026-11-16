#!/usr/bin/env python3
"""Check the actual built Info.plist, not just a source build setting."""
import plistlib
import sys
from pathlib import Path

path = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(__file__).resolve().parents[1] / "StayWeb/Info.plist"
if path.is_dir():
    path = path / "Info.plist"
value = plistlib.loads(path.read_bytes())
assert value["UIApplicationSceneManifest"]["UIApplicationSupportsMultipleScenes"] is False, "Kiosk must not allow a second scene"
assert "NSCameraUsageDescription" not in value and "NSMicrophoneUsageDescription" not in value
print("PASS: single-scene kiosk metadata; no added camera/microphone permissions")
