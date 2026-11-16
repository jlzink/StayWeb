import Foundation
import WebKit

/// Storage boundaries for a browser session. Owner browsing deliberately keeps
/// the pre-kiosk default store so an in-place update retains existing logins.
@MainActor
struct BrowserContext {
    let id: String
    let defaults: UserDefaults
    let dataStore: WKWebsiteDataStore
    let isGuest: Bool

    static var owner: BrowserContext {
        owner(defaults: .standard)
    }

    static func owner(defaults: UserDefaults) -> BrowserContext {
        BrowserContext(id: "owner", defaults: defaults, dataStore: .default(), isGuest: false)
    }

    static var supportsGuestProfiles: Bool {
        if #available(iOS 18.4, *) { return true }
        return false
    }

    /// iOS 18.4 is required to veto native file-upload panels. Named WebKit
    /// stores alone (iOS 17) cannot protect the owner's Files/Photos picker.
    @available(iOS 18.4, *)
    static func guest(id: UUID) throws -> BrowserContext {
        guard id.uuidString != "00000000-0000-0000-0000-000000000000" else {
            throw BrowserContextError.invalidProfile
        }
        let domain = preferencesDomain(for: id)
        guard let defaults = UserDefaults(suiteName: domain) else {
            throw BrowserContextError.unavailableStorage
        }
        // Never substitute the owner's default store if profile setup fails.
        return BrowserContext(id: id.uuidString, defaults: defaults,
                              dataStore: WKWebsiteDataStore(forIdentifier: id), isGuest: true)
    }

    static func preferencesDomain(for id: UUID) -> String {
        (Bundle.main.bundleIdentifier ?? "com.example.stayweb") + ".profile." + id.uuidString
    }
}

enum BrowserContextError: LocalizedError {
    case invalidProfile
    case unavailableStorage

    var errorDescription: String? {
        switch self {
        case .invalidProfile: return "This profile has an invalid storage identifier."
        case .unavailableStorage: return "Private browser storage could not be opened."
        }
    }
}
