import SwiftUI
import UIKit

@MainActor
protocol KioskLocking: AnyObject {
    var isActive: Bool { get }
    func request(enabled: Bool) async -> Bool
}

@MainActor
final class SystemKioskLock: KioskLocking {
    var isActive: Bool { UIAccessibility.isGuidedAccessEnabled }
    func request(enabled: Bool) async -> Bool {
        await withCheckedContinuation { continuation in
            UIAccessibility.requestGuidedAccessSession(enabled: enabled) { success in
                continuation.resume(returning: success)
            }
        }
    }
}

enum KioskLockMethod: String, CaseIterable, Identifiable {
    case guidedAccess, managedAutomatic
    var id: String { rawValue }
    var title: String {
        switch self {
        case .guidedAccess: return "Guided Access"
        case .managedAutomatic: return "Managed automatic lock"
        }
    }
}

/// The persistent switch is only an intent to use kiosk mode. It is never proof
/// that iPadOS has restricted the device, nor proof that an owner authenticated.
@MainActor
final class KioskController: ObservableObject {
    @Published private(set) var enabled: Bool
    @Published private(set) var method: KioskLockMethod
    @Published private(set) var lockActive: Bool
    @Published private(set) var browser: TabStore?
    @Published private(set) var activeProfile: StayWebProfile?
    @Published private(set) var ownerPanelPresented = false
    @Published private(set) var busy = false
    @Published private(set) var privacyCovered = false
    @Published var message: String?
    let profiles: ProfileStore

    private let defaults: UserDefaults
    private let lock: KioskLocking
    private let owner: OwnerAuthenticating
    private let supportsProfiles: Bool
    private var applicationActive = true
    private var generation = UUID()
    private var ownsAutomaticSession = false
    private var observers: [NSObjectProtocol] = []
    private let snapshotShield = KioskSnapshotShield()

    convenience init(admin: AdminCodeAuthenticator) {
        self.init(profiles: ProfileStore(), defaults: .standard, lock: SystemKioskLock(),
                  owner: admin, supportsProfiles: BrowserContext.supportsGuestProfiles,
                  observeLifecycle: true)
    }

    init(profiles: ProfileStore, defaults: UserDefaults,
         lock: KioskLocking, owner: OwnerAuthenticating,
         supportsProfiles: Bool, observeLifecycle: Bool = false) {
        self.profiles = profiles
        self.defaults = defaults
        self.lock = lock
        self.owner = owner
        self.supportsProfiles = supportsProfiles
        enabled = defaults.bool(forKey: "kiosk.enabled.v1")
        method = KioskLockMethod(rawValue: defaults.string(forKey: "kiosk.method.v1") ?? "") ?? .guidedAccess
        lockActive = lock.isActive
        // A kiosk cold start has no selected or authenticated profile.
        browser = enabled ? nil : TabStore(context: .owner)
        if observeLifecycle { observeSystemEvents() }
    }

    var guestProfilesSupported: Bool { supportsProfiles }
    var canStartGuest: Bool {
        enabled && lockActive && lock.isActive && supportsProfiles && applicationActive && !busy
    }
    var canRequestAutomaticExit: Bool { ownsAutomaticSession }

    func start() async {
        refreshLockState()
        if enabled, method == .managedAutomatic, !lock.isActive { await startAutomaticLock() }
    }

    func openOwnerControls() async {
        guard !busy else { return }
        browser?.tabs.forEach { $0.browser.webView.pauseAllMediaPlayback(completionHandler: nil) }
        let request = generation
        busy = true
        defer { busy = false }
        do {
            try await owner.authenticate(reason: "Enter the StayWeb admin code to manage kiosk users and settings.",
                                         allowSetup: !enabled)
            guard generation == request, applicationActive else { return }
            ownerPanelPresented = true
            message = nil
        } catch { if generation == request { message = error.localizedDescription } }
    }

    func closeOwnerControls() { ownerPanelPresented = false }

    func setMethod(_ value: KioskLockMethod) {
        guard ownerPanelPresented, !enabled, !busy else { return }
        method = value
        defaults.set(value.rawValue, forKey: "kiosk.method.v1")
    }

    func enableKiosk() async {
        guard ownerPanelPresented, !busy else { return }
        guard supportsProfiles else {
            message = "Kiosk profiles need iOS or iPadOS 18.4 or newer to protect access to device files."
            return
        }
        guard !profiles.profiles.isEmpty, profiles.loadError == nil else {
            message = "Create a user profile before starting kiosk mode."
            return
        }
        enabled = true
        defaults.set(true, forKey: "kiosk.enabled.v1")
        ownerPanelPresented = false
        lockSession()
        refreshLockState()
        if method == .managedAutomatic { await startAutomaticLock() }
        else if !lockActive { message = "Start Guided Access using the device's accessibility shortcut. Browsing stays locked until iPadOS confirms the session."
        }
    }

    func startAutomaticLock() async {
        guard enabled, method == .managedAutomatic, !busy else { return }
        guard !lock.isActive else {
            refreshLockState()
            message = "A system lock is already active. Its original Guided Access or management controls govern how it ends."
            return
        }
        let request = generation
        busy = true
        let success = await lock.request(enabled: true)
        busy = false
        refreshLockState()
        // Merely observing a pre-existing lock cannot identify or own its source.
        if success, lock.isActive { ownsAutomaticSession = true }
        guard request == generation, applicationActive else { return }
        if !success || !lockActive {
            message = "Automatic locking requires a supervised device and MDM permission for StayWeb. Guest browsing remains locked until a system lock is active."
        } else { message = nil }
    }

    func signIn(profile: StayWebProfile, pin: String) async -> Bool {
        refreshLockState()
        guard canStartGuest else {
            message = "Activate Guided Access or the managed lock before signing in."
            return false
        }
        let request = generation
        busy = true
        defer { busy = false }
        do {
            let accepted = try await profiles.authenticate(profileID: profile.id, pin: pin)
            guard request == generation, enabled, lock.isActive, applicationActive, !Task.isCancelled else { return false }
            guard accepted else { message = "That profile PIN was not accepted."; return false }
            guard #available(iOS 18.4, *) else { return false }
            let context = try BrowserContext.guest(id: profile.id)
            retireBrowser()
            activeProfile = profile
            browser = TabStore(context: context)
            message = nil
            return true
        } catch {
            if generation == request { message = error.localizedDescription }
            return false
        }
    }

    func lockSession() {
        generation = UUID()
        retireBrowser()
        activeProfile = nil
    }

    /// Admin-code verification is repeated for leaving kiosk mode, even if the owner
    /// settings sheet is already open. Manual/fixed locks are not ours to remove.
    func endKiosk() async {
        guard ownerPanelPresented, !busy, enabled else { return }
        let request = generation
        busy = true
        defer { busy = false }
        do {
            try await owner.authenticate(reason: "Enter the StayWeb admin code to leave kiosk mode.", allowSetup: false)
            guard request == generation, applicationActive else { return }
            if lock.isActive {
                guard ownsAutomaticSession else {
                    message = "End Guided Access with the system shortcut, or end a fixed Single App Mode in your management software. Then choose End Kiosk again."
                    return
                }
                retireBrowser()
                activeProfile = nil
                let success = await lock.request(enabled: false)
                // The status notification intentionally locks the guest session;
                // owner authentication remains valid only while foregrounded.
                guard applicationActive, ownerPanelPresented else { return }
                guard success, !lock.isActive else {
                    message = "iPadOS did not release the lock. StayWeb remains in kiosk mode."
                    return
                }
            }
            finishKioskExit()
        } catch { if request == generation { message = error.localizedDescription } }
    }

    func refreshLockState() {
        let now = lock.isActive
        if lockActive != now {
            lockActive = now
            if !now {
                ownsAutomaticSession = false
                if enabled { lockSession() }
            }
        }
        if enabled, !now, browser != nil { lockSession() }
    }

    func becameInactive() {
        privacyCovered = true
        snapshotShield.cover()
        // The admin challenge belongs to StayWeb, not a system credential panel.
        // Any interruption revokes it and requires a new code on return.
        owner.cancel()
        ownerPanelPresented = false
        if enabled { lockSession() }
        else { generation = UUID() }
    }

    func enteredBackground() {
        applicationActive = false
        privacyCovered = true
        snapshotShield.cover()
        owner.cancel()
        ownerPanelPresented = false
        generation = UUID()
        if enabled { lockSession() }
    }

    func becameActive() {
        applicationActive = true
        refreshLockState()
        privacyCovered = false
        snapshotShield.uncover()
        profiles.reload()
    }

    private func finishKioskExit() {
        guard !lock.isActive else { return }
        enabled = false
        defaults.set(false, forKey: "kiosk.enabled.v1")
        ownsAutomaticSession = false
        ownerPanelPresented = false
        lockSession()
        browser = TabStore(context: .owner)
        message = "Kiosk mode ended. You can now leave StayWeb."
    }

    private func retireBrowser() {
        browser?.shutdown()
        browser = nil
    }

    private func observeSystemEvents() {
        let center = NotificationCenter.default
        for name in [UIAccessibility.guidedAccessStatusDidChangeNotification,
                     UIApplication.willResignActiveNotification,
                     UIApplication.didEnterBackgroundNotification,
                     UIApplication.didBecomeActiveNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                // Notifications registered on the main queue are synchronous;
                // cover presented UI before the system captures a snapshot.
                MainActor.assumeIsolated {
                    guard let self else { return }
                    switch note.name {
                    case UIAccessibility.guidedAccessStatusDidChangeNotification: self.refreshLockState()
                    case UIApplication.willResignActiveNotification: self.becameInactive()
                    case UIApplication.didEnterBackgroundNotification: self.enteredBackground()
                    default: self.becameActive()
                    }
                }
            })
        }
    }
}

/// Cover our windows, including sheets and in-app media presentations. This is
/// snapshot privacy inside StayWeb; it is not an attempt to cover other apps.
@MainActor
private final class KioskSnapshotShield {
    private var covers: [UIView] = []
    func cover() {
        guard covers.isEmpty else { return }
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        for window in scenes.flatMap(\.windows) where !window.isHidden {
            let view = UIView(frame: window.bounds)
            view.backgroundColor = .systemBackground
            view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            let label = UILabel()
            label.text = "StayWeb • Locked"
            label.font = .preferredFont(forTextStyle: .title1)
            label.textColor = .label
            label.textAlignment = .center
            label.frame = view.bounds
            label.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            view.addSubview(label)
            window.addSubview(view)
            covers.append(view)
        }
    }
    func uncover() { covers.forEach { $0.removeFromSuperview() }; covers.removeAll() }
}
