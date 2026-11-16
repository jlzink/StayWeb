import XCTest
import CryptoKit
import Security
@testable import StayWeb

final class AdminCodeStoreTests: XCTestCase {
    @MainActor
    func testConfigurationPersistsAndDoesNotUseAGuestPIN() async throws {
        let adminStorage = MemoryAdminStorage()
        let guestStorage = MemoryAdminStorage()
        let admin = AdminCodeStore(storage: adminStorage, hasher: AdminTestHasher())
        let guests = ProfileStore(storage: guestStorage, hasher: AdminTestHasher())
        XCTAssertFalse(admin.isConfigured)
        XCTAssertNil(admin.loadError)
        let guest = try await guests.createProfile(name: "Guest", pin: "987654")
        try await admin.configure(code: "123456")
        XCTAssertTrue(admin.isConfigured)
        let restored = AdminCodeStore(storage: adminStorage, hasher: AdminTestHasher())
        XCTAssertTrue(restored.isConfigured)
        let guestCode = try await restored.authenticate(code: "987654")
        let adminCode = try await restored.authenticate(code: "123456")
        XCTAssertFalse(guestCode)
        XCTAssertTrue(adminCode)
        let guestStillWorks = try await guests.authenticate(profileID: guest.id, pin: "987654")
        XCTAssertTrue(guestStillWorks)
    }

    @MainActor
    func testFirstSetupCannotReplaceExistingOrMalformedStorage() async throws {
        let storage = MemoryAdminStorage()
        let admin = AdminCodeStore(storage: storage, hasher: AdminTestHasher())
        try await admin.configure(code: "123456")
        let configured = storage.data
        await expect(.alreadyConfigured) { try await admin.configure(code: "654321") }
        XCTAssertEqual(storage.data, configured)
        for malformed in [
            Data("not a registry".utf8),
            Data(#"{"version":1,"records":[]}"#.utf8)
        ] {
            storage.data = malformed
            let writes = storage.writes
            let broken = AdminCodeStore(storage: storage, hasher: AdminTestHasher())
            XCTAssertNotNil(broken.loadError)
            XCTAssertFalse(broken.isConfigured)
            await expect(.corruptStorage) { try await broken.configure(code: "654321") }
            await expect(.corruptStorage) { _ = try await broken.authenticate(code: "123456") }
            XCTAssertEqual(storage.data, malformed)
            XCTAssertEqual(storage.writes, writes)
        }
    }

    @MainActor
    func testExactlyOneAdministratorRecordIsRequired() async throws {
        let storage = MemoryAdminStorage()
        let admin = AdminCodeStore(storage: storage, hasher: AdminTestHasher())
        try await admin.configure(code: "123456")
        let original = try XCTUnwrap(storage.data)
        var envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: original) as? [String: Any])
        let records = try XCTUnwrap(envelope["records"] as? [[String: Any]])
        envelope["records"] = records + records
        storage.data = try JSONSerialization.data(withJSONObject: envelope)
        admin.reload()
        XCTAssertNotNil(admin.loadError)
        await expect(.corruptStorage) { _ = try await admin.authenticate(code: "123456") }
        await expect(.corruptStorage) { try await admin.configure(code: "654321") }
    }

    @MainActor
    func testUnavailableStorageAndFailedSuccessWriteNeverAuthorize() async throws {
        let storage = MemoryAdminStorage()
        storage.failReads = true
        let admin = AdminCodeStore(storage: storage, hasher: AdminTestHasher())
        XCTAssertNotNil(admin.loadError)
        await expect(.unavailable(errSecInteractionNotAllowed)) { try await admin.configure(code: "123456") }
        XCTAssertNil(storage.data)
        storage.failReads = false
        admin.reload()
        try await admin.configure(code: "123456")
        storage.failOnWrite = storage.writes + 2
        await expect(.unavailable(errSecInteractionNotAllowed)) {
            _ = try await admin.authenticate(code: "123456")
        }
    }

    @MainActor
    func testAdminThrottlePersistsAcrossStoreRecreation() async throws {
        let storage = MemoryAdminStorage()
        let clock = AdminTestClock()
        let admin = AdminCodeStore(storage: storage, hasher: AdminTestHasher(), now: { clock.date })
        try await admin.configure(code: "123456")
        for _ in 0..<5 {
            let accepted = try await admin.authenticate(code: "000000")
            XCTAssertFalse(accepted)
        }
        let restored = AdminCodeStore(storage: storage, hasher: AdminTestHasher(), now: { clock.date })
        await expect(.throttled(until: clock.date.addingTimeInterval(30))) {
            _ = try await restored.authenticate(code: "123456")
        }
        clock.date.addTimeInterval(31)
        let accepted = try await restored.authenticate(code: "123456")
        XCTAssertTrue(accepted)
    }

    @MainActor
    func testChangeRequiresCurrentCodeAndRejectsInvalidNewCode() async throws {
        let storage = MemoryAdminStorage()
        let admin = AdminCodeStore(storage: storage, hasher: AdminTestHasher())
        try await admin.configure(code: "123456")
        let original = storage.data
        await expect(.invalidCode) { try await admin.changeCode(currentCode: "123456", newCode: "123") }
        XCTAssertEqual(storage.data, original)
        await expect(.incorrectCurrentCode) { try await admin.changeCode(currentCode: "000000", newCode: "654321") }
        let oldStillWorks = try await admin.authenticate(code: "123456")
        XCTAssertTrue(oldStillWorks)
        try await admin.changeCode(currentCode: "123456", newCode: "654321")
        let oldRejected = try await admin.authenticate(code: "123456")
        let newAccepted = try await admin.authenticate(code: "654321")
        XCTAssertFalse(oldRejected)
        XCTAssertTrue(newAccepted)
    }

    @MainActor
    func testConcurrentInitialSetupCannotOverwriteTheFirstCompletedCode() async throws {
        let storage = MemoryAdminStorage()
        let started = expectation(description: "Initial admin code derivation started")
        let gate = AdminGatedHasher(blockCall: 1, started: started)
        defer { gate.release.signal() }
        let slow = AdminCodeStore(storage: storage, hasher: gate)
        let first = Task { try await slow.configure(code: "111111") }
        await fulfillment(of: [started], timeout: 3)
        let fast = AdminCodeStore(storage: storage, hasher: AdminTestHasher())
        try await fast.configure(code: "222222")
        let configured = storage.data
        gate.release.signal()
        await expect(.alreadyConfigured) { try await first.value }
        XCTAssertEqual(storage.data, configured)
        let completedCodeWorks = try await fast.authenticate(code: "222222")
        let staleCodeRejected = try await fast.authenticate(code: "111111")
        XCTAssertTrue(completedCodeWorks)
        XCTAssertFalse(staleCodeRejected)
    }

    @MainActor
    func testPendingAuthenticationIsInvalidatedByAnAdminCodeChange() async throws {
        let storage = MemoryAdminStorage()
        let owner = AdminCodeStore(storage: storage, hasher: AdminTestHasher())
        try await owner.configure(code: "123456")
        let started = expectation(description: "Admin authentication derivation started")
        let gate = AdminGatedHasher(blockCall: 1, started: started)
        defer { gate.release.signal() }
        let other = AdminCodeStore(storage: storage, hasher: gate)
        let attempt = Task { try await other.authenticate(code: "123456") }
        await fulfillment(of: [started], timeout: 3)
        try await owner.changeCode(currentCode: "123456", newCode: "654321")
        gate.release.signal()
        await expect(.changed) { _ = try await attempt.value }
    }

    @MainActor
    func testPendingCodeChangeCannotReplaceANewerAdminCode() async throws {
        let storage = MemoryAdminStorage()
        let owner = AdminCodeStore(storage: storage, hasher: AdminTestHasher())
        try await owner.configure(code: "123456")
        let started = expectation(description: "Replacement admin code derivation started")
        let gate = AdminGatedHasher(blockCall: 2, started: started)
        defer { gate.release.signal() }
        let other = AdminCodeStore(storage: storage, hasher: gate)
        let pending = Task { try await other.changeCode(currentCode: "123456", newCode: "111111") }
        await fulfillment(of: [started], timeout: 3)
        try await owner.changeCode(currentCode: "123456", newCode: "222222")
        let latest = storage.data
        gate.release.signal()
        await expect(.changed) { try await pending.value }
        XCTAssertEqual(storage.data, latest)
        let latestWorks = try await owner.authenticate(code: "222222")
        let staleRejected = try await owner.authenticate(code: "111111")
        XCTAssertTrue(latestWorks)
        XCTAssertFalse(staleRejected)
    }

    @MainActor
    func testCancelledSetupDoesNotCreateAnAdminCode() async throws {
        let storage = MemoryAdminStorage()
        let started = expectation(description: "Admin setup derivation started")
        let gate = AdminGatedHasher(blockCall: 1, started: started)
        defer { gate.release.signal() }
        let admin = AdminCodeStore(storage: storage, hasher: gate)
        let setup = Task { try await admin.configure(code: "123456") }
        await fulfillment(of: [started], timeout: 3)
        setup.cancel()
        gate.release.signal()
        do {
            try await setup.value
            XCTFail("Cancelled setup must not commit an admin code")
        } catch is CancellationError {}
        XCTAssertNil(storage.data)
        XCTAssertFalse(admin.isConfigured)
    }

    @MainActor
    private func expect(_ expected: AdminCodeStoreError,
                        file: StaticString = #filePath, line: UInt = #line,
                        operation: () async throws -> Void) async {
        do {
            try await operation()
            XCTFail("Expected \(expected)", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? AdminCodeStoreError, expected, file: file, line: line)
        }
    }
}

@MainActor
private final class MemoryAdminStorage: ProfileCredentialStorage {
    var data: Data?
    var failReads = false
    var writes = 0
    var failOnWrite: Int?
    func read() throws -> Data? {
        if failReads { throw ProfileStoreError.storageUnavailable(errSecInteractionNotAllowed) }
        return data
    }
    func write(_ value: Data) throws {
        writes += 1
        if writes == failOnWrite { throw ProfileStoreError.storageUnavailable(errSecInteractionNotAllowed) }
        data = value
    }
}

@MainActor
private final class AdminTestClock {
    var date = Date(timeIntervalSince1970: 1_800_000_000)
}

/// Lightweight test-only derivation; production defaults to CommonCrypto PBKDF2.
private struct AdminTestHasher: ProfilePINHashing {
    func derive(pin: String, salt: Data, iterations: UInt32) throws -> Data {
        Data(SHA256.hash(data: salt + Data(pin.utf8)))
    }
}

private final class AdminGatedHasher: ProfilePINHashing, @unchecked Sendable {
    let release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var calls = 0
    private let blockCall: Int
    private let started: XCTestExpectation
    init(blockCall: Int, started: XCTestExpectation) {
        self.blockCall = blockCall
        self.started = started
    }
    func derive(pin: String, salt: Data, iterations: UInt32) throws -> Data {
        lock.lock()
        calls += 1
        let shouldBlock = calls == blockCall
        lock.unlock()
        if shouldBlock {
            started.fulfill()
            guard release.wait(timeout: .now() + 5) == .success else { throw AdminCodeStoreError.busy }
        }
        return try AdminTestHasher().derive(pin: pin, salt: salt, iterations: iterations)
    }
}
