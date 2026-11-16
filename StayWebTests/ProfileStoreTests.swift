import XCTest
import CryptoKit
import Security
@testable import StayWeb

final class ProfileStoreTests: XCTestCase {
    func testPBKDF2SHA256KnownVector() throws {
        // PBKDF2-HMAC-SHA256("password", "salt", 2, 32), independent known vector.
        let result = try PBKDF2ProfilePINHasher().derive(
            pin: "password", salt: Data("salt".utf8), iterations: 2)
        XCTAssertEqual(result.map { String(format: "%02x", $0) }.joined(),
                       "ae4d0c95af6b46d32d0adff928f06dd02a303f8ef3c251dfd6e2d85a95474c43")
    }

    @MainActor
    func testPINValidationRejectsShortUnicodeAndUnboundedInput() {
        XCTAssertTrue(ProfileStore.isValidPIN("012345"))
        XCTAssertTrue(ProfileStore.isValidPIN(String(repeating: "7", count: 32)))
        for pin in ["", "12345", "123456 ", "١٢٣٤٥٦", "１２３４５６", "12345a", String(repeating: "8", count: 33)] {
            XCTAssertFalse(ProfileStore.isValidPIN(pin), "Rejected PIN shape: \(pin.count) characters")
        }
    }

    @MainActor
    func testSeparateProfilesHaveDifferentSaltAndPersistentIdentity() async throws {
        let storage = MemoryProfileStorage()
        let store = ProfileStore(storage: storage, hasher: FastTestHasher())
        let first = try await store.createProfile(name: "  First  ", pin: "123456")
        let second = try await store.createProfile(name: "Second", pin: "123456")
        XCTAssertEqual(first.name, "First")
        XCTAssertNotEqual(first.id, second.id)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(storage.data)) as? [String: Any])
        let records = try XCTUnwrap(object["records"] as? [[String: Any]])
        let one = try XCTUnwrap(records[0]["credential"] as? [String: Any])
        let two = try XCTUnwrap(records[1]["credential"] as? [String: Any])
        XCTAssertNotEqual(one["salt"] as? String, two["salt"] as? String)
        XCTAssertNotEqual(one["verifier"] as? String, two["verifier"] as? String)
        XCTAssertEqual(one["iterations"] as? Int, 600_000)
        XCTAssertNil(one["pin"])
        let restored = ProfileStore(storage: storage, hasher: FastTestHasher())
        XCTAssertEqual(restored.profiles, [first, second])
        let accepted = try await restored.authenticate(profileID: first.id, pin: "123456")
        XCTAssertTrue(accepted)
        let rejected = try await restored.authenticate(profileID: second.id, pin: "654321")
        XCTAssertFalse(rejected)
    }

    @MainActor
    func testFailureDelaySurvivesRecreationAndSuccessfulLoginResetsIt() async throws {
        let storage = MemoryProfileStorage()
        let clock = TestProfileClock()
        let store = ProfileStore(storage: storage, hasher: FastTestHasher(), now: { clock.date })
        let profile = try await store.createProfile(name: "Guest", pin: "123456")
        for _ in 0..<5 {
            let result = try await store.authenticate(profileID: profile.id, pin: "000000")
            XCTAssertFalse(result)
        }
        let restored = ProfileStore(storage: storage, hasher: FastTestHasher(), now: { clock.date })
        await expect(.throttled(until: clock.date.addingTimeInterval(30))) {
            _ = try await restored.authenticate(profileID: profile.id, pin: "123456")
        }
        clock.date.addTimeInterval(31)
        let accepted = try await restored.authenticate(profileID: profile.id, pin: "123456")
        XCTAssertTrue(accepted)
        for _ in 0..<4 {
            let result = try await restored.authenticate(profileID: profile.id, pin: "000000")
            XCTAssertFalse(result)
        }
        let acceptedAfterFour = try await restored.authenticate(profileID: profile.id, pin: "123456")
        XCTAssertTrue(acceptedAfterFour)
    }

    @MainActor
    func testMalformedPINAttemptsAreAlsoThrottled() async throws {
        let storage = MemoryProfileStorage()
        let clock = TestProfileClock()
        let store = ProfileStore(storage: storage, hasher: FastTestHasher(), now: { clock.date })
        let profile = try await store.createProfile(name: "Guest", pin: "123456")
        for _ in 0..<5 {
            let result = try await store.authenticate(profileID: profile.id, pin: "")
            XCTAssertFalse(result)
        }
        await expect(.throttled(until: clock.date.addingTimeInterval(30))) {
            _ = try await store.authenticate(profileID: profile.id, pin: "123456")
        }
    }

    @MainActor
    func testCorruptRegistryCannotBeOverwrittenByCreation() async {
        let storage = MemoryProfileStorage()
        storage.data = Data("not a registry".utf8)
        let original = storage.data
        let store = ProfileStore(storage: storage, hasher: FastTestHasher())
        XCTAssertNotNil(store.loadError)
        XCTAssertTrue(store.profiles.isEmpty)
        await expect(.corruptStorage) { _ = try await store.createProfile(name: "New", pin: "123456") }
        XCTAssertEqual(storage.data, original)
        XCTAssertEqual(storage.writes, 0)
    }

    @MainActor
    func testCorruptWorkFactorAndDuplicateProfileIDsFailClosed() async throws {
        let storage = MemoryProfileStorage()
        let store = ProfileStore(storage: storage, hasher: FastTestHasher())
        _ = try await store.createProfile(name: "Guest", pin: "123456")
        let original = try XCTUnwrap(storage.data)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: original) as? [String: Any])
        var records = try XCTUnwrap(object["records"] as? [[String: Any]])
        var credential = try XCTUnwrap(records[0]["credential"] as? [String: Any])
        credential["iterations"] = 4_000_000_000
        records[0]["credential"] = credential
        object["records"] = records
        storage.data = try JSONSerialization.data(withJSONObject: object)
        let corruptWork = ProfileStore(storage: storage, hasher: FastTestHasher())
        XCTAssertNotNil(corruptWork.loadError)
        XCTAssertTrue(corruptWork.profiles.isEmpty)

        object = try XCTUnwrap(JSONSerialization.jsonObject(with: original) as? [String: Any])
        records = try XCTUnwrap(object["records"] as? [[String: Any]])
        object["records"] = records + records
        storage.data = try JSONSerialization.data(withJSONObject: object)
        let corruptIDs = ProfileStore(storage: storage, hasher: FastTestHasher())
        XCTAssertNotNil(corruptIDs.loadError)
        XCTAssertTrue(corruptIDs.profiles.isEmpty)
    }

    @MainActor
    func testWriteFailureCannotPublishAProfileOrReturnAuthenticated() async throws {
        let storage = MemoryProfileStorage()
        let store = ProfileStore(storage: storage, hasher: FastTestHasher())
        storage.failOnWrite = 1
        await expect(.storageUnavailable(errSecInteractionNotAllowed)) {
            _ = try await store.createProfile(name: "Guest", pin: "123456")
        }
        XCTAssertTrue(store.profiles.isEmpty)
        XCTAssertNil(storage.data)
        storage.failOnWrite = nil
        let profile = try await store.createProfile(name: "Guest", pin: "123456")
        // Permit the attempt reservation but reject the success-state save.
        storage.failOnWrite = storage.writes + 2
        await expect(.storageUnavailable(errSecInteractionNotAllowed)) {
            _ = try await store.authenticate(profileID: profile.id, pin: "123456")
        }
        storage.failOnWrite = nil
        let restored = ProfileStore(storage: storage, hasher: FastTestHasher())
        let accepted = try await restored.authenticate(profileID: profile.id, pin: "123456")
        XCTAssertTrue(accepted)
    }

    @MainActor
    func testMissingCredentialsNeverAuthorizeKnownProfile() async throws {
        let storage = MemoryProfileStorage()
        let store = ProfileStore(storage: storage, hasher: FastTestHasher())
        let profile = try await store.createProfile(name: "Guest", pin: "123456")
        storage.data = nil
        await expect(.missingProfile) { _ = try await store.authenticate(profileID: profile.id, pin: "123456") }
    }

    @MainActor
    func testResetPreservesProfileIDAndChangesPIN() async throws {
        let storage = MemoryProfileStorage()
        let store = ProfileStore(storage: storage, hasher: FastTestHasher())
        let profile = try await store.createProfile(name: "Guest", pin: "123456")
        try store.rename(profileID: profile.id, name: "Renamed")
        for _ in 0..<5 {
            _ = try await store.authenticate(profileID: profile.id, pin: "000000")
        }
        try await store.resetPIN(profileID: profile.id, pin: "654321")
        XCTAssertEqual(store.profiles, [StayWebProfile(id: profile.id, name: "Renamed")])
        let old = try await store.authenticate(profileID: profile.id, pin: "123456")
        let new = try await store.authenticate(profileID: profile.id, pin: "654321")
        XCTAssertFalse(old)
        XCTAssertTrue(new)
    }

    @MainActor
    func testDuplicateAndInvalidCreationDoNotMutateStoredProfiles() async throws {
        let storage = MemoryProfileStorage()
        let store = ProfileStore(storage: storage, hasher: FastTestHasher())
        _ = try await store.createProfile(name: "Guest", pin: "123456")
        let original = storage.data
        await expect(.duplicateName) { _ = try await store.createProfile(name: " GUEST ", pin: "123456") }
        await expect(.invalidPIN) { _ = try await store.createProfile(name: "New", pin: "123") }
        await expect(.invalidName) { _ = try await store.createProfile(name: "\n ", pin: "123456") }
        XCTAssertEqual(storage.data, original)
    }

    @MainActor
    func testProfileEditIsAtomicWhenNameValidationFailsBeforeOrAfterDerivation() async throws {
        let storage = MemoryProfileStorage()
        let ownerStore = ProfileStore(storage: storage, hasher: FastTestHasher())
        let first = try await ownerStore.createProfile(name: "First", pin: "123456")
        let second = try await ownerStore.createProfile(name: "Second", pin: "987654")
        let original = storage.data
        await expect(.duplicateName) {
            try await ownerStore.updateProfile(profileID: first.id, name: "SECOND", pin: "654321")
        }
        await expect(.invalidName) {
            try await ownerStore.updateProfile(profileID: first.id, name: "\n ", pin: "654321")
        }
        XCTAssertEqual(storage.data, original)

        let started = expectation(description: "Edited PIN derivation started")
        let gatedHasher = GatedTestHasher(started: started)
        defer { gatedHasher.release.signal() }
        let editingStore = ProfileStore(storage: storage, hasher: gatedHasher)
        let edit = Task {
            try await editingStore.updateProfile(profileID: first.id, name: "Shared name", pin: "654321")
        }
        await fulfillment(of: [started], timeout: 3)
        try ownerStore.rename(profileID: second.id, name: "Shared name")
        let afterOtherEdit = storage.data
        gatedHasher.release.signal()
        await expect(.duplicateName) { try await edit.value }
        XCTAssertEqual(storage.data, afterOtherEdit, "Rejected edit must not save its newly derived PIN")
        let oldAccepted = try await ownerStore.authenticate(profileID: first.id, pin: "123456")
        let replacementRejected = try await ownerStore.authenticate(profileID: first.id, pin: "654321")
        XCTAssertTrue(oldAccepted)
        XCTAssertFalse(replacementRejected)

        let writes = storage.writes
        try await ownerStore.updateProfile(profileID: first.id, name: "Renamed", pin: "654321")
        XCTAssertEqual(storage.writes, writes + 1, "Name and PIN must commit in one storage write")
        XCTAssertEqual(ownerStore.profiles.first(where: { $0.id == first.id })?.name, "Renamed")
        let replacementAccepted = try await ownerStore.authenticate(profileID: first.id, pin: "654321")
        XCTAssertTrue(replacementAccepted)
    }

    @MainActor
    func testOwnerPINResetInvalidatesAlreadyRunningAuthentication() async throws {
        let storage = MemoryProfileStorage()
        let ownerStore = ProfileStore(storage: storage, hasher: FastTestHasher())
        let profile = try await ownerStore.createProfile(name: "Guest", pin: "123456")
        let started = expectation(description: "Background PIN derivation started")
        let gatedHasher = GatedTestHasher(started: started)
        defer { gatedHasher.release.signal() }
        let loginStore = ProfileStore(storage: storage, hasher: gatedHasher)
        let attempt = Task { try await loginStore.authenticate(profileID: profile.id, pin: "123456") }
        await fulfillment(of: [started], timeout: 3)
        try await ownerStore.updateProfile(profileID: profile.id, name: "Renamed", pin: "654321")
        gatedHasher.release.signal()
        await expect(.authenticationChanged) { _ = try await attempt.value }
        let new = try await ownerStore.authenticate(profileID: profile.id, pin: "654321")
        XCTAssertTrue(new)
    }

    @MainActor
    func testCancelledCreationCannotPublishAfterOwnerAuthorizationEnds() async throws {
        let storage = MemoryProfileStorage()
        let started = expectation(description: "New PIN derivation started")
        let gatedHasher = GatedTestHasher(started: started)
        defer { gatedHasher.release.signal() }
        let store = ProfileStore(storage: storage, hasher: gatedHasher)
        let creation = Task { try await store.createProfile(name: "Guest", pin: "123456") }
        await fulfillment(of: [started], timeout: 3)
        creation.cancel()
        gatedHasher.release.signal()
        do {
            _ = try await creation.value
            XCTFail("Cancelled creation must not commit a profile")
        } catch is CancellationError {
            // Cancellation is rechecked after the detached derivation finishes.
        }
        XCTAssertTrue(store.profiles.isEmpty)
        XCTAssertNil(storage.data)
    }

    @MainActor
    private func expect(_ expected: ProfileStoreError,
                        file: StaticString = #filePath, line: UInt = #line,
                        operation: () async throws -> Void) async {
        do {
            try await operation()
            XCTFail("Expected \(expected)", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? ProfileStoreError, expected, file: file, line: line)
        }
    }
}

@MainActor
private final class MemoryProfileStorage: ProfileCredentialStorage {
    var data: Data?
    var writes = 0
    var failOnWrite: Int?
    func read() throws -> Data? { data }
    func write(_ value: Data) throws {
        writes += 1
        if writes == failOnWrite { throw ProfileStoreError.storageUnavailable(errSecInteractionNotAllowed) }
        data = value
    }
}

@MainActor
private final class TestProfileClock {
    var date = Date(timeIntervalSince1970: 1_800_000_000)
}

/// Makes state-machine tests fast. Production always defaults to PBKDF2 above;
/// its actual CommonCrypto implementation is checked against a known vector.
private struct FastTestHasher: ProfilePINHashing {
    func derive(pin: String, salt: Data, iterations: UInt32) throws -> Data {
        Data(SHA256.hash(data: salt + Data(pin.utf8)))
    }
}

private final class GatedTestHasher: ProfilePINHashing, @unchecked Sendable {
    let release = DispatchSemaphore(value: 0)
    private let started: XCTestExpectation
    init(started: XCTestExpectation) { self.started = started }
    func derive(pin: String, salt: Data, iterations: UInt32) throws -> Data {
        started.fulfill()
        guard release.wait(timeout: .now() + 5) == .success else { throw ProfileStoreError.busy }
        return try FastTestHasher().derive(pin: pin, salt: salt, iterations: iterations)
    }
}
