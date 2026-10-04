# Validation

v0.1.0: GitHub run 37159950606 passed simulator compilation/XCTest and physical-device compilation/IPA packaging. User installed on iPhone and completed Disney+ login; the site then displayed `/get-app`.

v0.1.1 adds exact-host desktop identity, preserved preference decoding, and single-attempt gate recovery including same-document URL observation. New tests cover origin/path boundaries, recovery-loop limits, settings migration, and setting/clearing the identity before navigation. GitHub CI must pass before delivery. Actual Disney+ playback requires another device test.


0.1.2: Node fixtures cover scoped request rewriting, credentials, fetch response
text/json/clone, XHR text/json, and unrelated-site pass-through. A WebKit test
uses the real XML parser to remove an ad period while preserving ContentProtection
and the movie period, and leaves malformed/all-ad/no-ad manifests unchanged.
The full converted rule list must compile in WKContentRuleListStore. Actual
subscriber playback and all-ad removal remain unverified until device testing.
