#!/usr/bin/env python3
"""Select an available iPhone or iPad from the selected Xcode's iOS runtimes."""
import argparse
import json
import subprocess

parser = argparse.ArgumentParser()
parser.add_argument('--family', choices=['iphone', 'ipad'], default='iphone')
family = parser.parse_args().family
prefix = 'iPad' if family == 'ipad' else 'iPhone'
data = json.loads(subprocess.check_output(['xcrun', 'simctl', 'list', 'devices', 'available', '-j']))
for runtime, devices in sorted(data['devices'].items(), reverse=True):
    if '.iOS-' not in runtime:
        continue
    for device in devices:
        if device['isAvailable'] and device['name'].startswith(prefix):
            print(device['udid'])
            raise SystemExit(0)
raise SystemExit(f'No available {prefix} simulator. Inspect xcrun simctl list runtimes.')
