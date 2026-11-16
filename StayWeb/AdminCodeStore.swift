import Foundation
import Combine
import Security

enum AdminCodeStoreError: LocalizedError, Equatable, Sendable {
    case invalidCode
    case alreadyConfigured
    case notConfigured
    case incorrectCurrentCode
    case corruptStorage
    case changed
    case busy
    case unavailable(OSStatus)
    case derivationFailed
    case throttled(until: Date)

    var errorDescription: String? {
        switch self {
        case .invalidCode:
            return "Choose a StayWeb admin code containing 6–32 digits (0–9)."
        case .alreadyConfigured:
            return "A StayWeb admin code is already configured. Enter the current code to change it."
        case .notConfigured:
            return "Set up the StayWeb admin code first."
        case .incorrectCurrentCode:
            return "The current StayWeb admin code is incorrect."
        case .corruptStorage:
            return "The saved StayWeb admin code could not be verified. Administrator access remains locked; nothing was reset."
        case .changed:
            return "The StayWeb admin code changed during this request. Enter the current code again."
        case .busy:
            return "A StayWeb admin code is already being checked."
        case .unavailable(let status):
            return "StayWeb administrator storage is unavailable (\(status)). Unlock this device and try again."
        case .derivationFailed:
            return "The StayWeb admin code could not be checked. Try again."
        case .throttled(let until):
            return "Too many admin code attempts. Try again after \(until.formatted(date: .omitted, time: .standard))."
        }
    }
}

/// Independent from the device unlock code and every browsing-profile PIN.
/// Reuses the profile engine's PBKDF2, Keychain persistence, and attempt throttling
/// through a separate service restricted to exactly one administrator record.
@MainActor
final class AdminCodeStore: ObservableObject {
    @Published private(set) var isConfigured = false
    @Published private(set) var loadError: String?

    private let storage: ProfileCredentialStorage
    private let hasher: any ProfilePINHashing
    private let now: () -> Date

    init(storage: ProfileCredentialStorage? = nil,
         hasher: any ProfilePINHashing = PBKDF2ProfilePINHasher(),
         now: @escaping () -> Date = Date.init) {
        self.storage = storage ?? KeychainProfileStorage(
            service: (Bundle.main.bundleIdentifier ?? "com.example.stayweb") + ".administrator")
        self.hasher = hasher
        self.now = now
        reload()
    }

    static func isValidCode(_ code: String) -> Bool { ProfileStore.isValidPIN(code) }

    func reload() {
        do { _ = try configuration() }
        catch {
            isConfigured = false
            loadError = Self.translate(error).localizedDescription
        }
    }

    /// First setup only. Both the initial read and final write reject an existing
    /// Keychain item, including a malformed item or one created concurrently.
    func configure(code: String) async throws {
        guard Self.isValidCode(code) else { throw AdminCodeStoreError.invalidCode }
        do {
            let vault = AdminVaultStorage(base: storage, mode: .initialSetup)
            guard try vault.read() == nil else { throw AdminCodeStoreError.alreadyConfigured }
            let engine = ProfileStore(storage: vault, hasher: hasher, now: now)
            guard engine.loadError == nil else { throw AdminCodeStoreError.corruptStorage }
            _ = try await engine.createProfile(name: AdminVaultStorage.name, pin: code)
            _ = try configuration()
        } catch {
            reload()
            throw Self.translate(error)
        }
    }

    func authenticate(code: String) async throws -> Bool {
        do {
            guard let current = try configuration() else { throw AdminCodeStoreError.notConfigured }
            let accepted = try await current.engine.authenticate(profileID: current.state.profile.id, pin: code)
            // Never return a stale success after a concurrent code change.
            guard let latest = try configuration(), latest.state == current.state else {
                throw AdminCodeStoreError.changed
            }
            return accepted
        } catch {
            reload()
            throw Self.translate(error)
        }
    }

    func changeCode(currentCode: String, newCode: String) async throws {
        guard Self.isValidCode(newCode) else { throw AdminCodeStoreError.invalidCode }
        do {
            guard let current = try configuration() else { throw AdminCodeStoreError.notConfigured }
            guard try await current.engine.authenticate(profileID: current.state.profile.id, pin: currentCode) else {
                throw AdminCodeStoreError.incorrectCurrentCode
            }
            try Task.checkCancellation()
            // Bind this operation to the revision proved by currentCode. The
            // adapter checks again at commit, even if another change finishes
            // before this operation's replacement verifier does.
            let vault = AdminVaultStorage(base: storage, mode: .change(current.state))
            _ = try vault.read()
            let engine = ProfileStore(storage: vault, hasher: hasher, now: now)
            guard engine.loadError == nil else { throw AdminCodeStoreError.corruptStorage }
            try await engine.updateProfile(profileID: current.state.profile.id,
                                           name: AdminVaultStorage.name, pin: newCode)
            _ = try configuration()
        } catch {
            reload()
            throw Self.translate(error)
        }
    }

    private func configuration() throws -> (state: AdminVaultStorage.State, engine: ProfileStore)? {
        let vault = AdminVaultStorage(base: storage, mode: .normal)
        guard let data = try vault.read() else {
            isConfigured = false
            loadError = nil
            return nil
        }
        let state = try AdminVaultStorage.validate(data)
        let engine = ProfileStore(storage: vault, hasher: hasher, now: now)
        guard engine.loadError == nil, engine.profiles == [state.profile] else {
            throw AdminCodeStoreError.corruptStorage
        }
        isConfigured = true
        loadError = nil
        return (state, engine)
    }

    private static func translate(_ error: Error) -> Error {
        guard let error = error as? ProfileStoreError else { return error }
        switch error {
        case .invalidPIN: return AdminCodeStoreError.invalidCode
        case .duplicateName: return AdminCodeStoreError.alreadyConfigured
        case .missingProfile, .authenticationChanged: return AdminCodeStoreError.changed
        case .invalidName, .corruptStorage: return AdminCodeStoreError.corruptStorage
        case .storageUnavailable(let status): return AdminCodeStoreError.unavailable(status)
        case .derivationFailed: return AdminCodeStoreError.derivationFailed
        case .busy: return AdminCodeStoreError.busy
        case .throttled(let until): return AdminCodeStoreError.throttled(until: until)
        }
    }
}

@MainActor
private final class AdminVaultStorage: ProfileCredentialStorage {
    static let name = "StayWeb administrator"

    struct State: Equatable {
        let profile: StayWebProfile
        let revision: UUID
    }

    enum Mode {
        case normal
        case initialSetup
        case change(State)
    }

    private struct Envelope: Decodable {
        let version: Int
        let records: [Record]
        struct Record: Decodable {
            let profile: StayWebProfile
            let credential: Credential
        }
        struct Credential: Decodable { let revision: UUID }
    }

    private let base: ProfileCredentialStorage
    private let mode: Mode

    init(base: ProfileCredentialStorage, mode: Mode) {
        self.base = base
        self.mode = mode
    }

    static func validate(_ data: Data) throws -> State {
        guard let value = try? JSONDecoder().decode(Envelope.self, from: data),
              value.version == 1, value.records.count == 1,
              let record = value.records.first, record.profile.name == name else {
            throw AdminCodeStoreError.corruptStorage
        }
        return State(profile: record.profile, revision: record.credential.revision)
    }

    func read() throws -> Data? {
        guard let data = try base.read() else {
            if case .change = mode { throw AdminCodeStoreError.changed }
            return nil
        }
        let current = try Self.validate(data)
        if case .change(let expected) = mode, current != expected { throw AdminCodeStoreError.changed }
        return data
    }

    func write(_ data: Data) throws {
        let replacement = try Self.validate(data)
        switch mode {
        case .initialSetup:
            guard try base.read() == nil else { throw AdminCodeStoreError.alreadyConfigured }
        case .normal:
            guard let existing = try base.read(), try Self.validate(existing) == replacement else {
                throw AdminCodeStoreError.changed
            }
        case .change(let expected):
            guard let existing = try base.read(), try Self.validate(existing) == expected,
                  replacement.profile == expected.profile else { throw AdminCodeStoreError.changed }
        }
        try base.write(data)
    }
}
