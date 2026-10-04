#!/usr/bin/env python3
"""Portable source checks; these do NOT replace the Xcode simulator test job."""
import json
import plistlib
import re
import xml.etree.ElementTree as ET
from pathlib import Path

root = Path(__file__).resolve().parents[1]
rules = json.loads((root / 'StayWeb/Resources/blocker.json').read_text())
metadata = json.loads((root / 'StayWeb/Resources/filter-info.json').read_text())
assert metadata['prepared'], 'Run scripts/prepare_filters.py on macOS first'
assert 1000 < len(rules) <= 150000
assert metadata['ruleCount'] == len(rules)
for rule in rules:
    assert rule['action']['type'] in ['block', 'block-cookies', 'css-display-none', 'ignore-previous-rules', 'make-https']
    assert isinstance(rule['trigger']['url-filter'], str)
privacy = plistlib.loads((root / 'StayWeb/Resources/PrivacyInfo.xcprivacy').read_bytes())
assert privacy['NSPrivacyTracking'] is False
ET.parse(root / 'StayWeb.xcodeproj/xcshareddata/xcschemes/StayWeb.xcscheme')
project = (root / 'StayWeb.xcodeproj/project.pbxproj').read_text()
for folder in ['StayWeb', 'StayWebTests']:
    for path in (root / folder).rglob('*'):
        if any(parent.suffix == '.xcassets' for parent in path.parents):
            continue
        if path.suffix in ['.swift', '.json', '.xcprivacy', '.js', '.txt']:
            assert str(path.relative_to(root)) in project, f'Missing project file: {path}'
print('PASS: prepared filter count and structure, privacy plist, shared scheme and project source membership')
