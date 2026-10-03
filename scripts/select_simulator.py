#!/usr/bin/env python3
"""Select an available iPhone from the selected Xcode's installed iOS runtimes."""
import json
import subprocess

data = json.loads(subprocess.check_output(['xcrun', 'simctl', 'list', 'devices', 'available', '-j']))
for runtime, devices in sorted(data['devices'].items(), reverse=True):
    if '.iOS-' not in runtime:
        continue
    for device in devices:
        if device['isAvailable'] and device['name'].startswith('iPhone'):
            print(device['udid'])
            raise SystemExit(0)
raise SystemExit('No available iPhone simulator. Inspect xcrun simctl list runtimes on this runner.')
