# Validation at source delivery

Passed locally:
- Python scripts compile; deterministic Xcode project regeneration.
- Xcode object IDs and resource/source references are internally consistent.
- Shared Xcode scheme is valid XML; privacy manifest is valid plist.
- Ad rule JSON and third-party scope; positive and negative domain-boundary checks.
- GitHub Actions YAML parses and defines simulator tests before unsigned IPA build.

Not run here:
- Xcode/Swift compilation (no Apple SDK installed in this environment).
- XCTest execution on iOS Simulator.
- Real-device installation, ad filtering, universal-link behavior, or Disney+ playback.

The included GitHub workflow performs compilation and XCTest when pushed.
Passing CI does not establish streaming compatibility.
