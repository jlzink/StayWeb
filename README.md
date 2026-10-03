# StayWeb — iPhone / iPad browser prototype

A native SwiftUI + WKWebView browser focused on staying on the web. Version 0.1.1,
iOS/iPadOS 16 or newer. One universal app target. No third-party application dependencies.

**Status:** v0.1.0 compiled and passed simulator tests on GitHub. A real iPhone
successfully logged in but Disney+ redirected to `/get-app`. v0.1.1 adds a scoped,
experimental desktop compatibility mode and one-shot recovery from that page.
Real-device playback is not yet validated. This is not a DRM bypass.

## Updating from 0.1.0

Sign/sideload the new IPA over the old app using the same Apple account and bundle
ID. Open Disney+ with both **Request desktop website** and **Disney+ desktop
compatibility** enabled (defaults). A prior per-site desktop-off choice is preserved;
turn it on if necessary. The update retains existing cookies when installed over
the old app with the same identity. If the download page persists, clear website
data from Settings and sign in again. Recovery tries `/home` only once per explicit
navigation/reload, then reports the remaining incompatibility instead of looping.

The compatibility mode sets a desktop Safari User-Agent using `customUserAgent`
before the first Disney+ request, and sets `navigator.platform` / `maxTouchPoints`
for the top-level Disney page at document start. It is limited to the exact
`disneyplus.com` and `www.disneyplus.com` HTTPS hosts. Other origins revert to their
normal identity. It does not add codecs or bypass DRM, and the service may still
reject playback. The `/home` recovery target is experimental and may change.


## Get your first GitHub build

1. Create a GitHub repository (suggested name: `StayWeb`). Private is fine.
2. Extract this ZIP. Put the **contents** of the `StayWeb` folder at the repository
   root. The root must contain `StayWeb.xcodeproj`, `.github`, `StayWeb`,
   `StayWebTests`, and `scripts`. Commit using GitHub Desktop or Git; this preserves
   the `.github` folder. Do not upload the ZIP itself as your source.
3. Push to GitHub. In **Actions → Build StayWeb**, open the new run.
   The workflow also supports **Run workflow** once it is on the default branch.
4. The first job compiles the app and runs XCTest on an available iPhone simulator.
   The second job builds for physical iPhones/iPads and packages an unsigned IPA.
5. Download **StayWeb-Unsigned-IPA** from the successful run's Artifacts section,
   unzip that artifact, and find `StayWeb-unsigned.ipa` inside it.

No Apple certificates, passwords or developer-team secrets are required to compile.
The workflow has read-only repository permissions and does not upload to Apple or
publish a release. Runner usage remains subject to your GitHub account's allowance.
It uses `macos-15` with Xcode 16.4. If GitHub later removes that Xcode installation,
update `DEVELOPER_DIR` in both jobs to an installed stable version and rerun tests.

## Installation: compilation is not signing

The IPA is intentionally unsigned and **cannot be installed just by tapping it**.
Use a signing/sideloading tool you trust that supports your current iOS version,
or sign and run this project through Xcode on a Mac with your own Apple account.
Personal-development installation may require Developer Mode and periodic renewal.
TestFlight/App Store distribution needs the appropriate Apple Developer membership,
a registered unique bundle ID, signing, provisioning, and a separate distribution
workflow. None of those credentials are included or requested by this project.

The default bundle ID is `com.example.stayweb`; for your own signed builds replace
that prefix in `scripts/generate_project.py`, then regenerate the project. The tests
use the `.tests` suffix. A distribution-ready app will also need proper app icons,
its privacy disclosures, and release validation.

## Included behavior

- URL/search bar, back/forward, reload/stop, native share sheet and swipe navigation.
- iPhone/iPad adaptive layout with portrait and landscape support.
- Desktop site requests enabled by default using WebKit's public desktop content
  mode. Disney+ additionally uses the opt-out compatibility identity described above.
  No private browser API.
- A bundled, deliberately small set of third-party ad/tracker network rules,
  compiled with `WKContentRuleListStore` before browsing is enabled.
- Persistent **exact-host** settings for ad blocking, desktop mode, and App Store
  redirects. Settings take effect on reload and are applied before main navigation.
- External non-web app schemes are always cancelled; the app never calls
  `UIApplication.open` to hand a website to another app.
- App Store HTTPS redirects are blocked by default. Turning this setting off lets
  the Store webpage load; it does not enable automatic external app launches.
- Tapped HTTP(S) GET links are loaded programmatically in the same web view to
  avoid the normal universal-link activation path. This is best effort, not a
  promise to suppress every OS-level handoff on every iOS release.
- Third-party cookies, DRM, codecs and platform restrictions remain under WebKit
  and the streaming service's control. No TLS-verification overrides.
- Inline playback, AirPlay and Picture in Picture enabled where the site/player
  supports them. Playback requires a user gesture.
- Clear cookies/cache/site storage with confirmation. Local preferences are kept.
- No app analytics, backend, telemetry, password capture or bundled credentials.
  Websites you visit still have their own data practices.

## Known prototype limits

One tab only; no bookmark/history manager, download manager, private mode, default
browser entitlement, background audio guarantee or content-filter updater. The
starter rules cover nine common ad/tracker domains and do not block every ad.
They do not guarantee removal of commercials embedded in streaming video.

Automatic script popups are blocked. User-tapped new-window links load in the same
tab. OAuth flows that depend on a separate window or external app may not work.
Native JavaScript dialog handling is not implemented. Ordinary HTTPS browsing is
the target; iOS transport-security defaults may reject insecure HTTP sites.

**No app-prompt CSS removal is shipped.** We have not inspected a live Disney+
login/player flow. Blindly hiding an overlay can leave an unusable page. Add a
narrowly scoped site adapter only after inspecting and testing the real page.

## First device test (on both iPhone and iPad)

1. Launch; confirm the start screen says starter rules are ready.
2. Open Disney+, sign in yourself, and attempt playback with desktop mode on.
3. If playback fails, disable ad blocking for that host and retry. Then test mobile
   mode. Record which combination reaches login, catalog, and actual playback.
4. If a download prompt remains, record a screenshot, device model, iOS version,
   and URL **without tokens or login parameters**. Do not share cookies/passwords.
5. Try a known App Store link and confirm it is blocked with a notice. Test again
   with the native streaming app installed to check universal-link behavior.
6. Check rotation, seek, subtitles, fullscreen, PiP and AirPlay if available.
7. Restart the app and revisit that exact host to confirm its settings persist.
8. Clear website data, revisit a site, and confirm the session has been cleared.

The browser can prevent some navigation patterns; it cannot force a service to
issue DRM keys or provide a compatible player. A failed Disney+ test is a
compatibility finding, not proof that desktop mode is malfunctioning.

## Development

Open `StayWeb.xcodeproj` in Xcode. Select scheme **StayWeb** and an iOS simulator.
The checked-in project has no CocoaPods, Swift package, Homebrew or XcodeGen setup.

```sh
python3 scripts/validate.py
# After adding/removing Swift or resource files:
python3 scripts/generate_project.py
```

`generate_project.py` deterministically generates the Xcode project and shared
scheme from the two source directories. CI rejects an out-of-date generated
project. Do not hand-edit the generated project; edit the generator instead.

XCTest covers URL normalization, App Store hostname boundaries, actual WebKit rule
compilation, and an actual WebKit navigation being rejected by the browser delegate.
The portable validator checks files and rule boundaries only; it cannot prove Swift
compilation or website behavior. CI uploads the `.xcresult` bundle and build logs.

## References

- https://developer.apple.com/documentation/webkit/wkcontentruleliststore
- https://developer.apple.com/documentation/webkit/wkwebpagepreferences
- https://developer.apple.com/documentation/webkit/wknavigationdelegate
- https://github.com/actions/runner-images/blob/main/images/macos/macos-15-Readme.md
- https://help.disneyplus.com/article/disneyplus-computer-browser-requirements
