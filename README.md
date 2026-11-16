## Version 0.3.0 — StayWeb kiosk and separate users

- Separate StayWeb admin code for owner controls, user management, and kiosk exit;
  independent of the device unlock code, with no device-code or biometric fallback.
- PIN-protected user profiles with independent persistent website stores, site
  preferences, and streaming shortcuts. Existing owner website logins are preserved.
- Guest browsing requires confirmed Guided Access or authorized Single App Mode.
  An ordinary app cannot provide its own operating-system app-switch lock.
- Guest upload, media-capture, app handoff, and document-preview restrictions;
  inactive/background transitions revoke administrator access and cover private UI.
- Kiosk profiles require iOS/iPadOS **18.4+**; ordinary browsing remains iOS 16+.

See [KIOSK.md](KIOSK.md) for setup, manual versus managed exit behavior, the separate
Guided Access passcode, and required physical-device validation. Build locally on
your MacBook Pro with `bash scripts/build-local.sh`. Builds and tests run on your
Mac; the repository does not start GitHub Actions builds.

## Version 0.2.1 — fullscreen

- Enables WebKit element fullscreen on every tab so website player fullscreen controls can work, including YouTube.
- Adds a **Fullscreen website** button (outward arrows) to hide the address bar, toolbar, and status bar on any website. The floating inward-arrows button exits without reloading the page.
- Browser fullscreen expands the whole website; use the player’s fullscreen control for video-only fullscreen. Embedded players still follow their site’s fullscreen permissions.
- Supports the existing portrait and landscape orientations. Real-device YouTube and other service playback checks remain required.

## Version 0.2.0 — streaming home and tabs

- New teal globe/shield/play app icon, packaged in an asset catalog for iPhone and iPad.
- Startup dashboard with 28 streaming services, service search, and persistent custom shortcuts.
- Tab switcher with new, select and close actions; closing the last tab creates a fresh start page.
- Each tab keeps its own WebKit view and navigation history during the app session. Tabs are not restored after app termination.
- Touch and hold a service to open it in a new tab. Tapped target-blank web links also open a protected tab; unsolicited popups remain blocked.
- Switching tabs pauses media in the previous tab. Press play to resume when returning.
- Shared website login storage and site settings, with the existing streaming filters retained.

Use the same signing identity and bundle ID as the previous build to update it in place.

# StayWeb — iPhone / iPad browser prototype

A native SwiftUI + WKWebView browser focused on staying on the web. Version 0.3.0,
iOS/iPadOS 16 or newer (18.4+ for kiosk profiles). One universal app target. No
third-party application dependencies.

**Current validation:** the kiosk update still requires compilation and XCTest on
your Mac, followed by the physical-device checks in [KIOSK.md](KIOSK.md). Portable
source checks do not establish that the app builds or that the OS lock works.

**Earlier validation:** v0.1.0 compiled and passed simulator tests on GitHub. A real iPhone
successfully logged in but Disney+ redirected to `/get-app`. v0.1.1 adds a scoped,
experimental desktop compatibility mode and one-shot recovery from that page.
Real-device playback is not yet validated. This is not a DRM bypass.

## Updating from an earlier build

Sign/sideload the new IPA over the old app using the same Apple account and bundle
ID. Open Disney+ with both **Request desktop website** and **Disney+ desktop
compatibility** enabled (defaults). A prior per-site desktop-off choice is preserved;
turn it on if necessary. The update retains existing cookies when installed over
the old app with the same identity. If the download page persists, clear website
data from Settings and sign in again. Recovery tries `/home` only once per explicit
navigation/reload, then reports the remaining incompatibility instead of looping.

The compatibility mode sets a desktop Safari User-Agent using `customUserAgent`
before the first Disney+ request, and sets `navigator.platform` / `maxTouchPoints`
for supported top-level streaming pages at document start. Version 0.1.2 uses
this identity for HTTPS Disney+, Prime Video, Hulu and Peacock domain families
when desktop mode is enabled. Other origins revert to their normal identity. It does not add codecs or bypass DRM, and the service may still
reject playback. The `/home` recovery target is experimental and may change.


## Build locally on your MacBook Pro

Install Xcode 16.4 or a compatible newer version, launch it once to finish setup,
and install an iPad simulator runtime for iPadOS 18.4 or newer. In Xcode's
**Settings → Locations**, select that Xcode installation for Command Line Tools.
The build also uses Python 3. Internet access is needed to prepare the bundled
content filters.
On Intel Macs, filter preparation compiles the converter from the verified
SafariConverterLib 4.3.0 source revision using Xcode's Swift toolchain. Its
upstream prebuilt converter does not run on Intel. Swift Package Manager fetches
the converter's pinned dependencies on the first preparation run.

From the StayWeb project folder, run:

```sh
bash scripts/build-local.sh
```

This command prepares the filters, validates the source, runs XCTest on an iPad
simulator, and builds an unsigned physical-device app. It saves the combined log,
test result bundle, and build products in a timestamped `build/local/` folder.
It uses the checked-in Xcode project and preserves local signing settings.
If Node.js is available, it also runs the JavaScript filter fixtures; otherwise it
reports that optional check as skipped and continues with the native tests.

No Apple certificates, passwords, or developer-team secrets are required for these
unsigned builds. GitHub remains the source repository; automatic cloud builds have
been removed. Installation on your iPad is a separate local Xcode step below.

## First build with your Apple developer account

1. In **Xcode → Settings → Apple Accounts** (called **Accounts** in some versions),
   add the Apple Account used for your developer membership.
2. Open `StayWeb.xcodeproj`. Select the **StayWeb** app target, then
   **Signing & Capabilities**. Enable **Automatically manage signing** and choose
   your developer team. If both a Personal Team and your paid membership's team
   appear, choose the membership's team.
3. Set a bundle identifier available to your team. The checked-in
   `com.example.stayweb` is a placeholder. If updating an installed copy, first
   check its existing bundle ID and developer team; retaining both is the normal
   update path. A change of team or bundle ID needs separate migration planning
   before assuming that existing website logins will carry over.
4. Select the same team for **StayWebTests** if Xcode asks. Its bundle identifier
   should use the app identifier followed by `.tests`.
5. Connect and unlock your iPad, accept its **Trust This Computer** prompt, and
   choose it as Xcode's run destination. Click **Register** if Xcode offers it;
   automatic signing manages the development provisioning profile.
6. On the iPad, enable **Settings → Privacy & Security → Developer Mode** when
   prompted, restart, and confirm. This allows development builds to run; it does
   not enable kiosk restrictions.
7. After the local build/test command succeeds, choose **Product → Run** in Xcode
   to sign, install, and launch StayWeb with your account.

The local validation script builds without signing, so it can diagnose source
and test failures independently of account setup. Its unsigned device output is
not directly installable; Xcode's **Run** step creates the signed development app.

Personal-development installation may require Developer Mode and periodic renewal.
TestFlight/App Store distribution needs the appropriate Apple Developer membership,
a registered unique bundle ID, signing, provisioning, and a separate distribution
workflow. None of those credentials are included or requested by this project.

The default bundle ID is `com.example.stayweb`. If you previously changed it for
your installed copy, retain that value. The generator also contains the default
identifier, so update it before regenerating a project with a custom identifier.
The tests use the `.tests` suffix. Distribution requires its own privacy
disclosures and release validation.

## Included behavior

- URL/search bar, back/forward, reload/stop, native share sheet and swipe navigation.
- iPhone/iPad adaptive layout with portrait and landscape support.
- Desktop site requests enabled by default using WebKit's public desktop content
  mode. The four supported streaming services also use a desktop compatibility identity.
  No private browser API.
- A bundled snapshot of Ultimate Ad Filter converted to WebKit rules,
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

No bookmark/history manager, download manager, private mode, default
browser entitlement, background audio guarantee or content-filter updater. The
bundled filters are refreshed at build time rather than automatically on device.
They do not guarantee removal of commercials embedded in streaming video.

Automatic script popups are blocked. User-tapped new-window links open a protected
tab. OAuth flows that depend on an external app may not work.
Native JavaScript dialog handling is not implemented. Ordinary HTTPS browsing is
the target; iOS transport-security defaults may reject insecure HTTP sites.

**No app-prompt CSS removal is shipped.** We have not inspected a live Disney+
login/player flow. Blindly hiding an overlay can leave an unusable page. Add a
narrowly scoped site adapter only after inspecting and testing the real page.

## First device test (on both iPhone and iPad)

1. Launch; confirm the start screen shows more than 1,000 rules ready. Settings must show version 0.3.0 and the filter snapshot version.
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
python3 scripts/prepare_filters.py
python3 scripts/validate.py
node scripts/test_prime_filter.js
# After adding/removing Swift or resource files:
python3 scripts/generate_project.py
```

`generate_project.py` deterministically generates the Xcode project and shared
scheme from the two source directories. Run it after adding or removing source
files, preserving your bundle ID and signing settings in the generator before
regeneration. Routine local builds do not regenerate the project.

XCTest covers URL normalization, App Store hostname boundaries, actual WebKit rule
compilation, and an actual WebKit navigation being rejected by the browser delegate.
The portable validator checks files and generated rule metadata only; it cannot prove Swift
compilation or website behavior. The local build command saves the `.xcresult`
bundle and build log on your Mac.

## References

- https://developer.apple.com/documentation/webkit/wkcontentruleliststore
- https://developer.apple.com/documentation/webkit/wkwebpagepreferences
- https://developer.apple.com/documentation/webkit/wknavigationdelegate
- https://developer.apple.com/documentation/xcode/building-and-running-an-app
- https://developer.apple.com/documentation/xcode/enabling-developer-mode-on-a-device
- https://help.disneyplus.com/article/disneyplus-computer-browser-requirements


## 0.1.2 ad filtering update

The build downloads one Ultimate Ad Filter snapshot and converts it using the
checksum-pinned SafariConverterLib 4.3.0 tool. Run `python3 scripts/prepare_filters.py`
on macOS before building locally. The build script does this automatically;
simulator tests and the device build use the same snapshot. The preparation step
saves the source list and metadata in the project for auditing.
Settings show the converted rule count and source version. No remote JavaScript is executed.
See bundled FilterCredits.txt for attribution and license links.

Separate, default-on per-service settings inject an original document-start
filter on HTTPS Prime Video, Disney+, Hulu and Peacock pages. It removes known ad cuepoint JSON fields,
known ad periods from MPD responses, and ad-insertion playback request parameters.
Fetch and XHR responses are handled; native media requests, workers, binary reads,
and unlisted services are not covered by these JavaScript hooks. This is not a port
of every Chrome extension rule. Turn the service streaming filter off if playback fails.

Automated fixtures verify request/response behavior and WebKit XML processing.
Successful paid streaming playback and absence of ads require device testing
with a subscriber account; automated tests do not prove those outcomes. Disney
compatibility remains experimental. Installation from Xcode requires signing.

Disney+ and Hulu use scoped JSON ad-field pruning; Hulu also filters known ad
periods in DASH manifests. Peacock removes known ad-avail metadata while keeping
unrelated pagination fields. The full network list includes Peacock SSAI/tracking
rules. Desktop mode uses a desktop Safari identity on these four service domains;
only Disney+ has the bounded /get-app recovery. No service is claimed verified
until a device playback test succeeds. Hulu prototype-wide overrides from the
reference list are intentionally not included because they affect every object.
