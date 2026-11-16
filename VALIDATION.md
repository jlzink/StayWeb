# Validation

## Version 0.3.0 — kiosk profiles and independent admin code

New automated coverage exercises independent persistent WebKit stores; mandatory
guest restrictions; PIN persistence, corruption, throttling, and cancellation;
admin-code setup/change races; lock-state gating; refused managed exit; and old-tab
retirement. The local build script selects an iPad simulator and verifies the built app's
single-scene Info.plist. The admin code has no device-passcode/biometric fallback.

Source checks alone do not establish kiosk containment. The physical-device checks
in `KIOSK.md` remain required for Guided Access/ASAM, app switching, restart,
snapshots, fullscreen media, and system Password AutoFill or sharing interfaces.
No personal iPad has been erased, supervised, enrolled, or configured by this change.

Builds and XCTest now run locally on the MacBook Pro. Run
`bash scripts/build-local.sh` from the project folder; the timestamped
`build/local/` directory contains `build.log`, `Tests.xcresult`,
`DeviceBuild.xcresult`, and the simulator and device build products. The log also
records whether optional Node.js fixtures passed or were skipped. GitHub Actions
builds are disabled.

The kiosk update has passed portable source and JavaScript fixture checks. It has
not yet completed Xcode compilation or XCTest. Its earlier cloud run was cancelled
when the build destination changed to the local Mac. This document does not claim
that an unrun suite passed.

The first Intel Mac build reached filter preparation, where the upstream
ConverterTool executable returned `Bad CPU type in executable`. Preparation now
builds SafariConverterLib 4.3.0 from its pinned source revision on Intel Macs.
Xcode compilation and XCTest remain pending another local run.

## Earlier versions

v0.1.0: GitHub run 37159950606 passed simulator compilation/XCTest and physical-device compilation/IPA packaging. User installed on iPhone and completed Disney+ login; the site then displayed `/get-app`.

v0.1.1 adds exact-host desktop identity, preserved preference decoding, and single-attempt gate recovery including same-document URL observation. Tests cover origin/path boundaries, recovery-loop limits, settings migration, and setting/clearing the identity before navigation. Actual Disney+ playback requires another device test.


0.1.2: Node fixtures cover scoped request rewriting, credentials, fetch response
text/json/clone, XHR text/json, and unrelated-site pass-through. A WebKit test
uses the real XML parser to remove an ad period while preserving ContentProtection
and the movie period, and leaves malformed/all-ad/no-ad manifests unchanged.
The full converted rule list must compile in WKContentRuleListStore. Actual
subscriber playback and all-ad removal remain unverified until device testing.

Additional 0.1.2 DOM fixtures passed locally for Disney/Hulu/Peacock fetch
text, JSON and clone reads, and namespaced Hulu/Prime manifests. To reproduce:

```sh
npm install --prefix build/test-deps --ignore-scripts --no-audit --no-fund jsdom@26.1.0
NODE_PATH=build/test-deps/node_modules node scripts/test_streaming_dom.cjs
```

These fixture checks preserve movie URLs and DRM metadata; they do not replace
real subscriber playback testing.
