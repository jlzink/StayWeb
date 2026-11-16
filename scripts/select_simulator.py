#!/usr/bin/env python3
"""Select a suitable available iPhone or iPad from the selected local Xcode."""
import argparse
import json
import re
import subprocess


def version(text):
    if not re.fullmatch(r'\d+(?:\.\d+){0,2}', text):
        raise argparse.ArgumentTypeError('Use an OS version such as 18.4 or 18.4.1')
    parts = tuple(map(int, text.split('.')))
    return parts + (0,) * (3 - len(parts))


parser = argparse.ArgumentParser()
parser.add_argument('--family', choices=['iphone', 'ipad'], default='iphone')
parser.add_argument('--minimum-os', type=version, default='16.0',
                    help='Minimum iOS Simulator version, for example 18.4 (default: 16.0)')
args = parser.parse_args()
prefix = 'iPad' if args.family == 'ipad' else 'iPhone'
try:
    output = subprocess.check_output(['xcrun', 'simctl', 'list', 'devices', 'available', '-j'])
    data = json.loads(output)
except (OSError, subprocess.CalledProcessError, json.JSONDecodeError) as error:
    raise SystemExit(f'Could not list local simulators: {error}. Open full Xcode and finish its setup.')

candidates = []
for runtime, devices in data.get('devices', {}).items():
    match = re.search(r'\.iOS-(\d+(?:-\d+){1,2})$', runtime)
    if not match:
        continue
    runtime_version = version(match.group(1).replace('-', '.'))
    if runtime_version < args.minimum_os:
        continue
    for device in devices:
        if device.get('isAvailable') and device.get('name', '').startswith(prefix):
            # Prefer a booted device within the numerically newest runtime.
            candidates.append((runtime_version, device.get('state') == 'Booted', device['udid']))
if candidates:
    print(max(candidates)[2])
else:
    minimum = '.'.join(map(str, args.minimum_os[:2]))
    raise SystemExit(
        f'No available {prefix} simulator with iOS {minimum} or newer. '
        'In Xcode Settings, install a compatible iOS Simulator runtime; then create an '
        f'{prefix} simulator in Window > Devices and Simulators. Rerun this local build afterward.'
    )
