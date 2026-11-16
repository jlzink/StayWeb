#!/usr/bin/env python3
"""Prepare one verified AdGuard filter snapshot for simulator and device builds."""

import hashlib
import json
import pathlib
import platform
import plistlib
import subprocess
import urllib.request


root = pathlib.Path(__file__).resolve().parents[1]
out = root / 'build/filters'
out.mkdir(parents=True, exist_ok=True)
resources = root / 'StayWeb/Resources'

CONVERTER_VERSION = '4.3.0'
CONVERTER_COMMIT = '7a2e93f0afa70479cc59985f332025236c3f0c39'
CONVERTER_SHA256 = '6687be9f1a77abd5299299086c5fbffd0d1b5baec755eb4808aa2f53e275d3c0'


def download(url, path):
    with urllib.request.urlopen(url, timeout=120) as response:
        data = response.read()
    path.write_bytes(data)
    return hashlib.sha256(data).hexdigest()


def converter_for_host():
    """Use the verified release on Apple Silicon, or compile the pinned Intel tool."""
    if platform.machine() != 'x86_64':
        converter = out / 'ConverterTool'
        digest = download(
            f'https://github.com/AdguardTeam/SafariConverterLib/releases/download/v{CONVERTER_VERSION}/ConverterTool',
            converter,
        )
        if digest != CONVERTER_SHA256:
            raise RuntimeError('SafariConverterLib release checksum mismatch')
        converter.chmod(0o755)
        print(f'Using verified SafariConverterLib {CONVERTER_VERSION} release converter.', flush=True)
        return converter

    # The upstream release executable does not run on Intel Macs. Build the exact
    # release commit with the Swift toolchain from the selected local Xcode.
    source_dir = out / f'SafariConverterLib-v{CONVERTER_VERSION}'
    if not source_dir.exists():
        print('Fetching SafariConverterLib source for the Intel Mac.', flush=True)
        subprocess.run([
            'git', 'clone', '--depth', '1', '--branch', f'v{CONVERTER_VERSION}',
            'https://github.com/AdguardTeam/SafariConverterLib.git', str(source_dir),
        ], check=True)
    actual_commit = subprocess.check_output(
        ['git', '-C', str(source_dir), 'rev-parse', 'HEAD'], text=True,
    ).strip()
    if actual_commit != CONVERTER_COMMIT:
        raise RuntimeError('SafariConverterLib source does not match the pinned release commit')

    print('Building the pinned SafariConverterLib converter for Intel with local Xcode Swift.', flush=True)
    print('The first Swift Package Manager build may take several minutes.', flush=True)
    subprocess.run([
        'xcrun', 'swift', 'build', '-c', 'release', '--product', 'ConverterTool',
    ], cwd=source_dir, check=True)
    converter = source_dir / '.build/release/ConverterTool'
    if not converter.is_file():
        raise RuntimeError(f'Swift build completed without the ConverterTool executable: {converter}')
    return converter


converter = converter_for_host()

# The upstream release CLI omits its SwiftPM resource bundle. Restore the
# resources from the exact swift-psl revision in the release's Package.resolved.
# A local SwiftPM build also has its generated resource bundle beside its binary.
bundle = out / 'swift-psl_PublicSuffixList.bundle'
bundle.mkdir(exist_ok=True)
(bundle / 'Info.plist').write_bytes(plistlib.dumps({
    'CFBundleIdentifier': 'org.adguard.swift-psl-resources',
    'CFBundleName': 'PublicSuffixList',
    'CFBundlePackageType': 'BNDL',
}))
psl_revision = '7ccee9d576d4ca45219440e346f61117f44c816f'
for name in ['common.bin', 'negated.bin', 'asterisk.bin', 'version.txt']:
    download(
        f'https://raw.githubusercontent.com/ameshkov/swift-psl/{psl_revision}/Sources/PublicSuffixList/Resources/{name}',
        bundle / name,
    )

source_url = 'https://filters.adavoid.org/ultimate-ad-filter.txt'
source = out / 'ultimate.txt'
source_sha = download(source_url, source)
lines = source.read_text().splitlines()
version = next(line.split(':', 1)[1].strip() for line in lines if line.startswith('! Version:'))
subprocess.run([
    str(converter), 'convert', '--input-path', str(source), '--safari-version', '16',
    '--advanced-blocking', 'false', '--safari-rules-json-path', str(resources / 'blocker.json'),
], check=True)
rules = json.loads((resources / 'blocker.json').read_text())
assert 1000 < len(rules) <= 150000, f'Unexpected rule count: {len(rules)}'
metadata = {
    'name': 'Ultimate Ad Filter', 'version': version, 'ruleCount': len(rules),
    'source': source_url, 'sourceSHA256': source_sha,
    'converter': f'SafariConverterLib {CONVERTER_VERSION}', 'prepared': True,
}
(resources / 'filter-info.json').write_text(json.dumps(metadata, indent=2) + '\n')
(out / 'filter-info.json').write_text(json.dumps(metadata, indent=2) + '\n')
print(f'Prepared {len(rules)} Safari rules, source {version}, SHA256 {source_sha}')
