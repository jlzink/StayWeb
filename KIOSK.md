# StayWeb kiosk profiles — 0.3.0

StayWeb is the browser and user interface for a shared device. Each person signs
in to a StayWeb profile with a profile PIN. A separate **StayWeb admin code**
protects administrator controls, profile management, and leaving kiosk mode.

The admin code is independent of the iPhone/iPad unlock code. There is no
device-passcode or biometric fallback in StayWeb. The application never asks for
or verifies the device unlock code.

## Requirements and scope

- Regular owner browsing continues to support iOS/iPadOS 16 and newer.
- Guest kiosk profiles require **iOS/iPadOS 18.4 or newer**. This version provides
  the public WebKit delegate needed to reject native file-upload pickers.
- An active **Guided Access** session or authorized **Single App Mode** is required
  before StayWeb will open a guest browser. A StayWeb setting cannot itself prevent
  Home gestures, app switching, or operating-system behavior.
- These are browser profiles, not full iPadOS user accounts. Other installed apps
  cannot run inside StayWeb. Websites and web applications run in its WebKit tabs.

The OS restriction prevents using other foreground apps while it is active.
StayWeb does not stop all background processes, replace the Home Screen, or place
an unclosable window over the operating system. System panels remain controlled
by iPadOS. Physical-device validation is required before relying on the kiosk.

## Set up on a personal iPad

1. Follow [the first developer-account build setup](README.md#first-build-with-your-apple-developer-account).
   To update an existing StayWeb installation, retain its bundle ID and developer
   team; do not assume an installation under a different team carries its data
   over. The existing default WebKit store remains the owner's store;
   existing owner website logins are not migrated into guest profiles.
2. Tap the shield at the left of the browser address bar to open **Owner Controls**.
3. On first setup, choose and confirm a StayWeb admin code of **6–32 digits**.
   Keep this code safe. Later visits ask for this code; StayWeb does not silently
   reset it if verification or storage fails.
4. Choose **Add User** and give each person a name and a separate 6–32 digit PIN.
   Names, PIN verifiers, and attempt counters are stored in device-only Keychain
   items. No default code is included.
5. Keep **Guided Access** selected as the lock method and choose **Start Kiosk**.
   StayWeb displays the user chooser, with sign-in disabled until the OS lock is
   active.
6. Configure Guided Access in **Settings → Accessibility → Guided Access**. Set
   its exit passcode and use the device's accessibility shortcut to start Guided
   Access while StayWeb is open.
7. Give the device to the user. They choose their profile and enter its PIN. The
   profile-lock button in the browser returns to the chooser and retires its tabs.

**Guided Access has its own passcode.** You may choose the same digits as the
StayWeb admin code, but they are separate settings. StayWeb cannot read, set, or
synchronize Apple's Guided Access passcode. If leaving must always require a code,
disable Face ID/Touch ID exit in Guided Access settings. Changing the StayWeb admin
code does not change the Guided Access exit passcode.

To leave a manually started kiosk, end Guided Access using the system shortcut
and its passcode. StayWeb closes any active guest browser when that lock ends.
Enter **Owner Controls**, then choose **End Kiosk** and enter the StayWeb admin code
again to restore the normal owner browser. An app button cannot remove an
externally imposed system restriction.

## Managed automatic mode

An organization can authorize StayWeb for **Autonomous Single App Mode** on a
supervised device through MDM. The allowed bundle identifier must match the
installed build. This is separate from membership in the Apple Developer Program.

Choose **Managed automatic lock** before starting kiosk mode. StayWeb asks iPadOS
to enter the restricted session and checks the actual system state. Failed
requests leave guest browsing closed. After a successful app-started lock, the
owner can choose **End Kiosk**, enter the separate admin code, and StayWeb requests
release. It restores owner browsing only if iPadOS confirms the restriction ended.

StayWeb does not claim ownership of a lock that was already active when it started.
A lock imposed by Apple Configurator, MDM App Lock, or a manually started Guided
Access session must be ended by its original controls. Apple Configurator's fixed
Single App Mode can reopen the selected app after restart; its management controls,
not an in-app code, govern release. Do not erase or supervise an existing personal
iPad merely to try this feature without planning that device change separately.

## What profiles separate

Each guest profile UUID selects a separate persistent `WKWebsiteDataStore` and a
separate preferences domain. Cookies, website storage, site settings, and custom
streaming shortcuts do not use the owner's default store. Opening another tab
within a profile uses that profile's same store. Clearing website data affects
the selected profile's store.

Guest profile PINs and the admin code use salted PBKDF2-HMAC-SHA256 verifiers and
persistent attempt throttling. The fifth unsuccessful attempt starts a 30-second
delay, increasing up to one hour. PINs gate access through StayWeb; they do not
individually encrypt WebKit's website database files.

Leaving a profile stops navigation, suspends media, closes media presentations,
disconnects delegates, and retires the old tabs. A cold kiosk launch starts at the
locked chooser. The active user and an authenticated administrator session are
never restored from preferences. Backgrounding or interruption revokes owner
controls and cancels pending code checks. An opaque cover protects StayWeb's
windows, including presented content, during system snapshot transitions.

## Guest browser restrictions

- External app schemes are rejected. App Store redirects remain blocked even if
  an older site preference had allowed them.
- The app's Share button, link previews, native link context menus, Picture in
  Picture, and AirPlay are disabled.
- Native file-upload requests are declined. Camera, microphone, and device-motion
  permission requests handled by the guest delegate are denied.
- Downloads and native document previews are declined for frame navigations,
  including embedded PDF frames. Ordinary web pages remain available.
- Multiple application scenes are disabled in the explicit Info.plist.

System Password AutoFill, passkeys, clipboard, keyboard state, text-selection
menus, and other WebKit/system panels are not separate iPad user environments.
Do not assume that removing the browser's Share button suppresses every system
sharing surface, including Web Share. The app does not grant guest websites
access to another native app's sandbox. Website behavior and streaming-service
compatibility still require device testing.

## Build and verification

Build and test locally on the MacBook Pro with Xcode 16.4 or a compatible newer
Xcode, Python 3, and an installed iPad simulator runtime for iPadOS 18.4 or newer.
From the project folder:

```sh
bash scripts/build-local.sh
```

The script prepares the existing maintained filters, checks the project, runs the
test suite on an available iPad simulator, compiles the device target without
signing, verifies that multiple scenes are disabled in the built app, and records
`build.log`, `Tests.xcresult`, and build products under a timestamped
`build/local/` folder. To install, open the existing Xcode project, retain the
same bundle identifier and developer team when updating, select the device and run.

GitHub Actions builds have been removed; compilation and XCTest run on your Mac.
Automated cases cover profile cookie separation, settings scope, persisted PIN
delays, malformed storage, failed writes, cancellation, concurrent code changes,
old-session retirement, refused lock acquisition, and refused lock release.

Before real use, verify on the actual iPad:

1. A correct guest PIN cannot open browsing without the OS lock.
2. Home/app-switch gestures cannot leave StayWeb while the lock is active.
3. Wrong/cancelled admin codes cannot change settings or release an automatic lock.
4. Ending the OS lock during sign-in closes the guest and rejects a late result.
5. Two profiles retain different website logins after switching and relaunching.
6. File inputs, PDF frames, capture prompts, sharing routes, and installed-app
   redirects cannot expose an unexpected native interface.
7. The app-switcher image does not show a private page, sheet, or fullscreen video.
8. A second StayWeb window cannot be opened, including through Stage Manager.
9. Restart/relaunch returns to the chooser; independently verify the chosen OS
   lock's restart behavior on the installed iPadOS version.
10. Inspect system Password AutoFill/passkey behavior with the device's actual
    account and biometric configuration.

## Apple documentation

- [Guided Access](https://support.apple.com/111795)
- [Programmatic Single App Mode requirements](https://developer.apple.com/documentation/uikit/uiaccessibility/requestguidedaccesssession(enabled:completionhandler:))
- [Apple Configurator Single App Mode](https://support.apple.com/guide/apple-configurator-mac/cadbf9c172/mac)
- [WebKit persistent profile stores](https://developer.apple.com/documentation/webkit/wkwebsitedatastore/init(foridentifier:))
- [WebKit in Safari 18.4, including file-upload delegate support](https://webkit.org/blog/16574/webkit-features-in-safari-18-4/)
