import XCTest
import CryptoKit
@testable import StayWeb

final class KioskControllerTests: XCTestCase {
    @MainActor
    private func environment(enabled: Bool = true, active: Bool = false,
                             method: KioskLockMethod = .guidedAccess,
                             supported: Bool = true) -> (KioskController, TestKioskLock, TestAdminAuthenticator) {
        let domain = "StayWeb.KioskTests." + UUID().uuidString
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: domain) }
        let defaults = UserDefaults(suiteName: domain)!
        defaults.set(enabled, forKey: "kiosk.enabled.v1")
        defaults.set(method.rawValue, forKey: "kiosk.method.v1")
        let profiles = ProfileStore(storage: TestProfileRegistry(), hasher: TestProfileHasher())
        let lock = TestKioskLock(active: active)
        let owner = TestAdminAuthenticator()
        let kiosk = KioskController(profiles: profiles, defaults: defaults,
                                   lock: lock, owner: owner, supportsProfiles: supported)
        return (kiosk, lock, owner)
    }

    @MainActor
    func testColdKioskStartNeverOpensOwnerOrRestoresAuthenticatedUser() {
        let (kiosk, _, _) = environment(active: true)
        XCTAssertNil(kiosk.browser)
        XCTAssertNil(kiosk.activeProfile)
        XCTAssertFalse(kiosk.ownerPanelPresented)
        XCTAssertTrue(kiosk.canStartGuest)
    }

    @MainActor
    func testUnrestrictedDeviceAndUnsupportedOSCannotStartGuest() async throws {
        let (kiosk, _, _) = environment()
        let profile = try await kiosk.profiles.createProfile(name: "Guest", pin: "123456")
        let accepted = await kiosk.signIn(profile: profile, pin: "123456")
        XCTAssertFalse(accepted)
        XCTAssertNil(kiosk.browser)
        let (unsupported, _, _) = environment(active: true, supported: false)
        XCTAssertFalse(unsupported.canStartGuest)
    }

    @MainActor
    func testProfileSessionClosesImmediatelyWhenSystemLockEnds() async throws {
        guard #available(iOS 18.4, *) else { throw XCTSkip("Guest profiles require iOS 18.4") }
        let (kiosk, lock, _) = environment(active: true)
        let profile = try await kiosk.profiles.createProfile(name: "Guest", pin: "123456")
        let accepted = await kiosk.signIn(profile: profile, pin: "123456")
        XCTAssertTrue(accepted)
        let previous = try XCTUnwrap(kiosk.browser)
        lock.isActive = false
        kiosk.refreshLockState()
        XCTAssertNil(kiosk.browser)
        XCTAssertNil(kiosk.activeProfile)
        XCTAssertTrue(previous.isRetired)
        XCTAssertTrue(kiosk.enabled, "A system-lock change must never expose the owner's browser")
    }

    @MainActor
    func testWrongOrCancelledAdminCodeCannotOpenControls() async {
        let (kiosk, _, owner) = environment()
        owner.fail = true
        await kiosk.openOwnerControls()
        XCTAssertFalse(kiosk.ownerPanelPresented)
        XCTAssertNil(kiosk.browser)
        XCTAssertTrue(kiosk.enabled)
    }

    @MainActor
    func testBackgroundInvalidatesPendingOwnerSuccess() async {
        let (kiosk, _, owner) = environment()
        owner.started = expectation(description: "StayWeb admin prompt started")
        owner.suspend = true
        let operation = Task { await kiosk.openOwnerControls() }
        await fulfillment(of: [owner.started!], timeout: 2)
        kiosk.enteredBackground()
        kiosk.becameActive()
        owner.complete()
        await operation.value
        XCTAssertFalse(kiosk.ownerPanelPresented)
        XCTAssertNil(kiosk.browser)
    }

    @MainActor
    func testInactiveCancelsAdminPromptAndRejectsLateSuccess() async {
        let (kiosk, _, owner) = environment()
        owner.started = expectation(description: "StayWeb admin prompt")
        owner.suspend = true
        let operation = Task { await kiosk.openOwnerControls() }
        await fulfillment(of: [owner.started!], timeout: 2)
        kiosk.becameInactive()
        XCTAssertFalse(owner.isAuthenticating, "An in-app admin prompt has no system-prompt exception")
        XCTAssertEqual(owner.cancelCalls, 1)
        XCTAssertFalse(kiosk.ownerPanelPresented)
        owner.complete()
        await operation.value
        kiosk.becameActive()
        XCTAssertFalse(kiosk.ownerPanelPresented, "Late success must not restore revoked admin authority")
        XCTAssertNil(kiosk.browser)
    }

    @MainActor
    func testInactiveRevokesAnOpenAdminPanel() async {
        let (kiosk, _, _) = environment()
        await kiosk.openOwnerControls()
        XCTAssertTrue(kiosk.ownerPanelPresented)
        kiosk.becameInactive()
        XCTAssertFalse(kiosk.ownerPanelPresented)
        kiosk.becameActive()
        XCTAssertFalse(kiosk.ownerPanelPresented)
    }

    @MainActor
    func testPersistedEnabledKioskNeverAllowsReplacingMissingAdminCode() async {
        let (kiosk, _, owner) = environment(enabled: true, active: true)
        owner.configured = false
        await kiosk.openOwnerControls()
        XCTAssertEqual(owner.setupPermissions, [false])
        XCTAssertFalse(owner.configured, "Missing admin credentials must not turn into first-run setup")
        XCTAssertFalse(kiosk.ownerPanelPresented)
        XCTAssertNil(kiosk.browser)
        XCTAssertTrue(kiosk.enabled)
    }

    @MainActor
    func testInitialAdminSetupIsAllowedOnlyBeforeKioskIsEnabled() async {
        let (kiosk, _, owner) = environment(enabled: false)
        owner.configured = false
        await kiosk.openOwnerControls()
        XCTAssertEqual(owner.setupPermissions, [true])
        XCTAssertTrue(owner.configured)
        XCTAssertTrue(kiosk.ownerPanelPresented)
    }

    @MainActor
    func testPreexistingSystemLockIsNeverClaimedOrReleased() async {
        let (kiosk, lock, owner) = environment(active: true, method: .managedAutomatic)
        await kiosk.start()
        await kiosk.startAutomaticLock()
        XCTAssertTrue(lock.requests.isEmpty)
        XCTAssertFalse(kiosk.canRequestAutomaticExit)
        await kiosk.openOwnerControls()
        await kiosk.endKiosk()
        XCTAssertEqual(owner.calls, 2, "Exit needs a fresh StayWeb admin-code request")
        XCTAssertTrue(lock.requests.isEmpty)
        XCTAssertTrue(kiosk.enabled)
        XCTAssertNil(kiosk.browser)
    }

    @MainActor
    func testManagedLockFailureDoesNotOpenBrowser() async {
        let (kiosk, lock, _) = environment(method: .managedAutomatic)
        lock.allowStart = false
        await kiosk.start()
        XCTAssertEqual(lock.requests, [true])
        XCTAssertFalse(kiosk.canStartGuest)
        XCTAssertFalse(kiosk.canRequestAutomaticExit)
        XCTAssertNil(kiosk.browser)
    }

    @MainActor
    func testOwnedManagedExitNeedsFreshAdminCodeAndConfirmedOSRelease() async {
        let (kiosk, lock, owner) = environment(method: .managedAutomatic)
        await kiosk.start()
        XCTAssertTrue(kiosk.canRequestAutomaticExit)
        await kiosk.openOwnerControls()
        owner.fail = true
        await kiosk.endKiosk()
        XCTAssertEqual(lock.requests, [true])
        XCTAssertTrue(kiosk.enabled)
        owner.fail = false
        lock.allowEnd = false
        await kiosk.endKiosk()
        XCTAssertTrue(kiosk.enabled)
        XCTAssertNil(kiosk.browser)
        lock.allowEnd = true
        await kiosk.endKiosk()
        XCTAssertEqual(owner.calls, 4)
        XCTAssertEqual(owner.setupPermissions, [false, false, false, false],
                       "An active kiosk must never offer replacement-admin setup")
        XCTAssertFalse(kiosk.enabled)
        XCTAssertFalse(lock.isActive)
        XCTAssertEqual(kiosk.browser?.context.id, "owner")
    }

    @MainActor
    func testManualModeCanOnlyReturnToOwnerAfterSystemLockIsEnded() async {
        let (kiosk, lock, _) = environment(active: true)
        await kiosk.openOwnerControls()
        await kiosk.endKiosk()
        XCTAssertTrue(kiosk.enabled)
        lock.isActive = false
        kiosk.refreshLockState()
        XCTAssertNil(kiosk.browser)
        await kiosk.endKiosk()
        XCTAssertFalse(kiosk.enabled)
        XCTAssertEqual(kiosk.browser?.context.id, "owner")
        XCTAssertTrue(lock.requests.isEmpty)
    }
}

@MainActor
private final class TestKioskLock: KioskLocking {
    var isActive: Bool
    var requests: [Bool] = []
    var allowStart = true
    var allowEnd = true
    init(active: Bool) { isActive = active }
    func request(enabled: Bool) async -> Bool {
        requests.append(enabled)
        guard enabled ? allowStart : allowEnd else { return false }
        isActive = enabled
        return true
    }
}

@MainActor
private final class TestAdminAuthenticator: OwnerAuthenticating {
    var isAuthenticating = false
    var calls = 0
    var cancelCalls = 0
    var configured = true
    var setupPermissions: [Bool] = []
    var fail = false
    var suspend = false
    var started: XCTestExpectation?
    private var continuation: CheckedContinuation<Void, Never>?
    func authenticate(reason: String, allowSetup: Bool) async throws {
        calls += 1
        setupPermissions.append(allowSetup)
        isAuthenticating = true
        defer { isAuthenticating = false }
        if suspend {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
                started?.fulfill()
            }
        }
        if fail || (!configured && !allowSetup) { throw AdminAuthenticationError.cancelled }
        if !configured { configured = true }
    }
    func complete() { continuation?.resume(); continuation = nil }
    // Simulate late verification success even after the in-app prompt closes:
    // the controller must independently reject the invalidated result.
    func cancel() { cancelCalls += 1; isAuthenticating = false }
}

@MainActor
private final class TestProfileRegistry: ProfileCredentialStorage {
    private var data: Data?
    func read() throws -> Data? { data }
    func write(_ data: Data) throws { self.data = data }
}

private struct TestProfileHasher: ProfilePINHashing {
    func derive(pin: String, salt: Data, iterations: UInt32) throws -> Data {
        Data(SHA256.hash(data: salt + Data(pin.utf8)))
    }
}
