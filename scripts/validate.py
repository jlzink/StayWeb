#!/usr/bin/env python3
"""Portable source checks; these do NOT replace the Xcode simulator test job."""
import json
import plistlib
import re
import xml.etree.ElementTree as ET
from pathlib import Path

root = Path(__file__).resolve().parents[1]
rules = json.loads((root / 'StayWeb/Resources/blocker.json').read_text())
assert len(rules) >= 1
for rule in rules:
    assert rule['action']['type'] == 'block'
    assert rule['trigger']['load-type'] == ['third-party']
    re.compile(rule['trigger']['url-filter'])
patterns = [re.compile(rule['trigger']['url-filter'], re.I) for rule in rules]
assert any(p.search('https://ad.doubleclick.net/ad') for p in patterns)
assert not any(p.search('https://doubleclick.net.example.com/ad') for p in patterns)
assert not any(p.search('https://www.disneyplus.com/') for p in patterns)
privacy = plistlib.loads((root / 'StayWeb/Resources/PrivacyInfo.xcprivacy').read_bytes())
assert privacy['NSPrivacyTracking'] is False
ET.parse(root / 'StayWeb.xcodeproj/xcshareddata/xcschemes/StayWeb.xcscheme')
project = (root / 'StayWeb.xcodeproj/project.pbxproj').read_text()
for folder in ['StayWeb', 'StayWebTests']:
    for path in (root / folder).rglob('*'):
        if path.suffix in ['.swift', '.json', '.xcprivacy']:
            assert str(path.relative_to(root)) in project, f'Missing project file: {path}'
print('PASS: rule structure/domain boundaries, privacy plist, shared scheme and project source membership')
