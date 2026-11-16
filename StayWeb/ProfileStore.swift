import Foundation
import Combine
import Security
import CommonCrypto

struct StayWebProfile: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    var name: String
}

enum ProfileStoreError: LocalizedError, Equatable, Sendable {
    case invalidName
    case invalidPIN
    case duplicateName
    case missingProfile
    case corruptStorage
    case storageUnavailable(OSStatus)
    case derivationFailed(Int32)
    case busy
    case authenticationChanged
    case throttled(until: Date)

    var errorDescription: String? {
        switch self {
        case .invalidName:
            return "Enter a profile name of 1–64 characters without line breaks."
        case .invalidPIN:
            return "Choose a profile PIN containing 6–32 digits (0–9)."
        case .duplicateName:
            return "A profile already uses that name."
        case .missingProfile:
            return "This profile is no longer available."
        case .corruptStorage:
            return "The saved profiles could not be verified. StayWeb has not reset or opened them. Owner recovery is required."
        case .storageUnavailable(let status):
            return "Profile storage is unavailable (\(status)). Unlock this device and try again."
        case .derivationFailed:
            return "The profile PIN could not be checked. Try again."
        case .busy:
            return "A sign-in for this profile is already being checked."
        case .authenticationChanged:
            return "The profile changed while signing in. Enter its current PIN again."
        case .throttled(let until):
            return "Too many PIN attempts. Try again after \(until.formatted(date: .omitted, time: .standard))."
        }
    }
}

/// One atomic, device-only Keychain item contains the registry and attempt counters.
/// These are StayWeb profile PINs; the iPad's unlock passcode is never collected.
@MainActor
protocol ProfileCredentialStorage {
    func read() throws -> Data?
    func write(_ data: Data) throws
}

@MainActor
final class KeychainProfileStorage: ProfileCredentialStorage {
    private let service: String
    private let account = "profile-registry.v1"

    init(service: String = (Bundle.main.bundleIdentifier ?? "com.example.stayweb") + ".profiles") {
        self.service = service
    }

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account,
         kSecAttrSynchronizable as String: false]
    }

    func read() throws -> Data? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw ProfileStoreError.storageUnavailable(status) }
        guard let data = result as? Data else { throw ProfileStoreError.corruptStorage }
        return data
    }

    func write(_ data: Data) throws {
        let update = [kSecValueData as String: data]
        var status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            status = SecItemAdd(item as CFDictionary, nil)
            if status == errSecDuplicateItem {
                status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
            }
        }
        guard status == errSecSuccess else { throw ProfileStoreError.storageUnavailable(status) }
    }
}

protocol ProfilePINHashing: Sendable {
    func derive(pin: String, salt: Data, iterations: UInt32) throws -> Data
}

struct PBKDF2ProfilePINHasher: ProfilePINHashing {
    func derive(pin: String, salt: Data, iterations: UInt32) throws -> Data {
        var output = Data(count: 32)
        let outputLength = output.count
        let status: Int32 = output.withUnsafeMutableBytes { outputBytes in
            salt.withUnsafeBytes { saltBytes in
                pin.withCString { password in
                    CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2),
                        password, pin.utf8.count,
                        saltBytes.bindMemory(to: UInt8.self).baseAddress, salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), iterations,
                        outputBytes.bindMemory(to: UInt8.self).baseAddress, outputLength)
                }
            }
        }
        guard status == kCCSuccess else { throw ProfileStoreError.derivationFailed(status) }
        return output
    }
}

@MainActor
final class ProfileStore: ObservableObject {
    @Published private(set) var profiles: [StayWebProfile] = []
    @Published private(set) var loadError: String?

    private static let iterations: UInt32 = 600_000
    private let storage: ProfileCredentialStorage
    private let hasher: any ProfilePINHashing
    private let now: () -> Date
    private var checking = Set<UUID>()

    private struct Credential: Codable, Sendable {
        var version = 1
        var algorithm = "pbkdf2-hmac-sha256"
        let salt: Data
        let verifier: Data
        let iterations: UInt32
        let revision: UUID
        var failures = 0
        var lockedUntil: Date?
        var pendingAttempt: UUID?
    }

    private struct Record: Codable, Sendable {
        var profile: StayWebProfile
        var credential: Credential
    }

    private struct Registry: Codable, Sendable {
        var version = 1
        var records: [Record] = []
    }

    init(storage: ProfileCredentialStorage? = nil,
         hasher: any ProfilePINHashing = PBKDF2ProfilePINHasher(),
         now: @escaping () -> Date = Date.init) {
        self.storage = storage ?? KeychainProfileStorage()
        self.hasher = hasher
        self.now = now
        reload()
    }

    /// Retry after the device becomes unlocked. A read error never creates an empty vault.
    func reload() {
        do { publish(try readRegistry()) }
        catch {
            profiles = []
            loadError = error.localizedDescription
        }
    }

    func createProfile(name: String, pin: String) async throws -> StayWebProfile {
        let name = try Self.validatedName(name)
        guard Self.isValidPIN(pin) else { throw ProfileStoreError.invalidPIN }
        try ensureUnique(name, in: readRegistry())
        let credential = try await newCredential(pin: pin)
        try Task.checkCancellation()
        // Another owner operation may have completed during key derivation.
        var registry = try readRegistry()
        try ensureUnique(name, in: registry)
        let profile = StayWebProfile(id: UUID(), name: name)
        registry.records.append(Record(profile: profile, credential: credential))
        try save(registry)
        return profile
    }

    /// Counts an attempt before expensive work so terminating the app cannot erase it.
    /// Success is returned only after clearing the counter has also persisted.
    func authenticate(profileID: UUID, pin: String) async throws -> Bool {
        guard checking.insert(profileID).inserted else { throw ProfileStoreError.busy }
        defer { checking.remove(profileID) }
        var registry = try readRegistry()
        guard let index = registry.records.firstIndex(where: { $0.profile.id == profileID }) else {
            throw ProfileStoreError.missingProfile
        }
        let date = now()
        if let until = registry.records[index].credential.lockedUntil, until > date {
            throw ProfileStoreError.throttled(until: until)
        }
        var credential = registry.records[index].credential
        credential.failures = min(credential.failures + 1, 64)
        let delay = Self.delay(after: credential.failures)
        credential.lockedUntil = delay > 0 ? date.addingTimeInterval(delay) : nil
        let attempt = UUID()
        credential.pendingAttempt = attempt
        registry.records[index].credential = credential
        try save(registry)

        // Invalid input is still an unsuccessful, rate-limited attempt.
        guard Self.isValidPIN(pin) else { return false }
        let hasher = self.hasher
        let reservedCredential = credential
        let candidate = try await Task.detached(priority: .userInitiated) {
            try hasher.derive(pin: pin, salt: reservedCredential.salt, iterations: reservedCredential.iterations)
        }.value
        try Task.checkCancellation()

        // Re-read to preserve concurrent renames and invalidate an in-flight old PIN
        // after an owner reset (or a second ProfileStore attempting authentication).
        registry = try readRegistry()
        guard let current = registry.records.firstIndex(where: { $0.profile.id == profileID }),
              registry.records[current].credential.revision == credential.revision,
              registry.records[current].credential.pendingAttempt == attempt else {
            throw ProfileStoreError.authenticationChanged
        }
        let correct = Self.matches(candidate, credential.verifier)
        registry.records[current].credential.pendingAttempt = nil
        if correct {
            registry.records[current].credential.failures = 0
            registry.records[current].credential.lockedUntil = nil
        }
        try save(registry)
        return correct
    }

    /// The caller must authenticate the owner before invoking owner mutations.
    func resetPIN(profileID: UUID, pin: String) async throws {
        guard Self.isValidPIN(pin) else { throw ProfileStoreError.invalidPIN }
        guard try readRegistry().records.contains(where: { $0.profile.id == profileID }) else {
            throw ProfileStoreError.missingProfile
        }
        let credential = try await newCredential(pin: pin)
        try Task.checkCancellation()
        var registry = try readRegistry()
        guard let index = registry.records.firstIndex(where: { $0.profile.id == profileID }) else {
            throw ProfileStoreError.missingProfile
        }
        registry.records[index].credential = credential
        try save(registry)
    }

    /// Atomically saves an owner edit. An invalid/duplicate name never changes the
    /// PIN, including when another edit introduces a collision during derivation.
    func updateProfile(profileID: UUID, name: String, pin: String?) async throws {
        let name = try Self.validatedName(name)
        if let pin, !Self.isValidPIN(pin) { throw ProfileStoreError.invalidPIN }
        let original = try readRegistry()
        guard let record = original.records.first(where: { $0.profile.id == profileID }) else {
            throw ProfileStoreError.missingProfile
        }
        try ensureUnique(name, in: original, excluding: profileID)

        let replacement: Credential?
        if let pin { replacement = try await newCredential(pin: pin) }
        else { replacement = nil }
        try Task.checkCancellation()

        var registry = try readRegistry()
        guard let index = registry.records.firstIndex(where: { $0.profile.id == profileID }) else {
            throw ProfileStoreError.missingProfile
        }
        try ensureUnique(name, in: registry, excluding: profileID)
        if let replacement {
            guard registry.records[index].credential.revision == record.credential.revision else {
                throw ProfileStoreError.authenticationChanged
            }
            registry.records[index].credential = replacement
        }
        registry.records[index].profile.name = name
        try save(registry)
    }

    func rename(profileID: UUID, name: String) throws {
        let name = try Self.validatedName(name)
        var registry = try readRegistry()
        guard let index = registry.records.firstIndex(where: { $0.profile.id == profileID }) else {
            throw ProfileStoreError.missingProfile
        }
        try ensureUnique(name, in: registry, excluding: profileID)
        registry.records[index].profile.name = name
        try save(registry)
    }

    static func isValidPIN(_ pin: String) -> Bool {
        (6...32).contains(pin.utf8.count) && pin.utf8.allSatisfy { (48...57).contains($0) }
    }

    private static func validatedName(_ value: String) throws -> String {
        let name = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...64).contains(name.count),
              !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw ProfileStoreError.invalidName
        }
        return name
    }

    private static func nameKey(_ name: String) -> String {
        name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }

    private func ensureUnique(_ name: String, in registry: Registry, excluding id: UUID? = nil) throws {
        guard !registry.records.contains(where: {
            $0.profile.id != id && Self.nameKey($0.profile.name) == Self.nameKey(name)
        }) else { throw ProfileStoreError.duplicateName }
    }

    private func newCredential(pin: String) async throws -> Credential {
        var salt = Data(count: 32)
        let saltCount = salt.count
        let status = salt.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, saltCount, $0.baseAddress!) }
        guard status == errSecSuccess else { throw ProfileStoreError.storageUnavailable(status) }
        let hasher = self.hasher
        let immutableSalt = salt
        let iterations = Self.iterations
        let verifier = try await Task.detached(priority: .userInitiated) {
            try hasher.derive(pin: pin, salt: immutableSalt, iterations: iterations)
        }.value
        guard verifier.count == 32 else { throw ProfileStoreError.corruptStorage }
        return Credential(salt: salt, verifier: verifier, iterations: iterations, revision: UUID())
    }

    private func readRegistry() throws -> Registry {
        guard let data = try storage.read() else { return Registry() }
        guard let registry = try? JSONDecoder().decode(Registry.self, from: data), registry.version == 1 else {
            throw ProfileStoreError.corruptStorage
        }
        var identifiers = Set<UUID>()
        var names = Set<String>()
        for record in registry.records {
            let value = record.credential
            guard let name = try? Self.validatedName(record.profile.name), name == record.profile.name,
                  identifiers.insert(record.profile.id).inserted,
                  names.insert(Self.nameKey(name)).inserted,
                  value.version == 1, value.algorithm == "pbkdf2-hmac-sha256",
                  value.salt.count == 32, value.verifier.count == 32,
                  (100_000...2_000_000).contains(value.iterations),
                  (0...64).contains(value.failures),
                  value.lockedUntil?.timeIntervalSince1970.isFinite != false,
                  (value.failures >= 5) == (value.lockedUntil != nil) else {
                throw ProfileStoreError.corruptStorage
            }
        }
        return registry
    }

    private func save(_ registry: Registry) throws {
        let data = try JSONEncoder().encode(registry)
        try storage.write(data)
        publish(registry)
    }

    private func publish(_ registry: Registry) {
        profiles = registry.records.map(\.profile)
        loadError = nil
    }

    private static func delay(after failures: Int) -> TimeInterval {
        guard failures >= 5 else { return 0 }
        return min(30 * pow(2, Double(min(failures - 5, 7))), 3_600)
    }

    private static func matches(_ first: Data, _ second: Data) -> Bool {
        guard first.count == 32, second.count == 32 else { return false }
        var difference: UInt8 = 0
        for (lhs, rhs) in zip(first, second) { difference |= lhs ^ rhs }
        return difference == 0
    }
}
