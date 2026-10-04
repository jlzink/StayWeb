#!/usr/bin/env python3
"""Snapshot maintained rules once per build; simulator and device use identical data."""
import hashlib, json, pathlib, subprocess, urllib.request
root = pathlib.Path(__file__).resolve().parents[1]
out = root/'build/filters'; out.mkdir(parents=True, exist_ok=True)
resources = root/'StayWeb/Resources'
def download(url, path):
    with urllib.request.urlopen(url, timeout=120) as response:
        data = response.read()
    path.write_bytes(data)
    return hashlib.sha256(data).hexdigest()
converter = out/'ConverterTool'
digest = download('https://github.com/AdguardTeam/SafariConverterLib/releases/download/v4.3.0/ConverterTool', converter)
assert digest == '6687be9f1a77abd5299299086c5fbffd0d1b5baec755eb4808aa2f53e275d3c0', 'Converter checksum mismatch'
converter.chmod(0o755)
source_url = 'https://filters.adavoid.org/ultimate-ad-filter.txt'
source = out/'ultimate.txt'
source_sha = download(source_url, source)
lines = source.read_text().splitlines()
version = next(line.split(':', 1)[1].strip() for line in lines if line.startswith('! Version:'))
subprocess.run([str(converter), 'convert', '--input-path', str(source), '--safari-version', '16', '--advanced-blocking', 'false', '--safari-rules-json-path', str(resources/'blocker.json')], check=True)
rules = json.loads((resources/'blocker.json').read_text())
assert 1000 < len(rules) <= 150000, f'Unexpected rule count: {len(rules)}'
metadata = {'name':'Ultimate Ad Filter', 'version':version, 'ruleCount':len(rules), 'source':source_url, 'sourceSHA256':source_sha, 'converter':'SafariConverterLib 4.3.0', 'prepared':True}
(resources/'filter-info.json').write_text(json.dumps(metadata, indent=2)+'\n')
(out/'filter-info.json').write_text(json.dumps(metadata, indent=2)+'\n')
print(f'Prepared {len(rules)} Safari rules, source {version}, SHA256 {source_sha}')
