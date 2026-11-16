import SwiftUI

@MainActor
protocol OwnerAuthenticating: AnyObject {
    var isAuthenticating: Bool { get }
    func authenticate(reason: String, allowSetup: Bool) async throws
    func cancel()
}

struct AdminCodePrompt: Identifiable {
    let id = UUID()
    let reason: String
    let isSetup: Bool
}

/// An in-app owner challenge. The admin credential is independent of the device
/// unlock code, guest PINs, and Apple's Guided Access exit credential.
@MainActor
final class AdminCodeAuthenticator: ObservableObject, OwnerAuthenticating {
    @Published private(set) var prompt: AdminCodePrompt?
    @Published private(set) var verifying = false
    @Published private(set) var error: String?
    let codes: AdminCodeStore
    private var continuation: CheckedContinuation<Void, Error>?
    private var verification: Task<Void, Never>?
    var isAuthenticating: Bool { continuation != nil }

    init(codes: AdminCodeStore) { self.codes = codes }

    func authenticate(reason: String, allowSetup: Bool) async throws {
        guard continuation == nil else { throw AdminAuthenticationError.busy }
        codes.reload()
        if let problem = codes.loadError { throw AdminAuthenticationError.unavailable(problem) }
        guard codes.isConfigured || allowSetup else { throw AdminAuthenticationError.notConfigured }
        error = nil
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                prompt = AdminCodePrompt(reason: reason, isSetup: !codes.isConfigured)
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancel() }
        }
        try Task.checkCancellation()
    }

    func submit(code: String, confirmation: String) {
        guard let challenge = prompt, !verifying else { return }
        guard AdminCodeStore.isValidCode(code) else {
            error = "Use an admin code containing 6–32 digits."
            return
        }
        guard !challenge.isSetup || code == confirmation else {
            error = "The two admin codes do not match."
            return
        }
        verifying = true
        error = nil
        verification = Task { [weak self] in
            guard let self else { return }
            do {
                let accepted: Bool
                if challenge.isSetup {
                    try await codes.configure(code: code)
                    accepted = true
                } else { accepted = try await codes.authenticate(code: code) }
                guard !Task.isCancelled, prompt?.id == challenge.id else { return }
                verifying = false
                verification = nil
                if accepted {
                    let finished = continuation
                    continuation = nil
                    prompt = nil
                    finished?.resume()
                } else { error = "That admin code was not accepted." }
            } catch {
                guard prompt?.id == challenge.id else { return }
                verifying = false
                verification = nil
                self.error = error.localizedDescription
            }
        }
    }

    func cancel() {
        verification?.cancel()
        verification = nil
        let pending = continuation
        continuation = nil
        prompt = nil
        verifying = false
        error = nil
        pending?.resume(throwing: AdminAuthenticationError.cancelled)
    }
}

enum AdminAuthenticationError: LocalizedError {
    case busy, cancelled, notConfigured, unavailable(String)
    var errorDescription: String? {
        switch self {
        case .busy: return "An admin-code request is already open."
        case .cancelled: return "Admin authorization was cancelled."
        case .notConfigured: return "The kiosk admin credential is missing. StayWeb will not create a replacement while kiosk mode is enabled."
        case .unavailable(let detail): return "Admin authorization is unavailable. \(detail)"
        }
    }
}

struct AdminCodePromptView: View {
    @ObservedObject var authentication: AdminCodeAuthenticator
    let prompt: AdminCodePrompt
    @State private var code = ""
    @State private var confirmation = ""
    @FocusState private var editing: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section(prompt.isSetup ? "Create your StayWeb admin code" : "StayWeb admin code") {
                    Text(prompt.reason)
                    SecureField("Admin code", text: $code)
                        .keyboardType(.numberPad).privacySensitive().focused($editing)
                    if prompt.isSetup {
                        SecureField("Confirm admin code", text: $confirmation)
                            .keyboardType(.numberPad).privacySensitive()
                        Text("Choose 6–32 digits. This is separate from the device unlock code and each user's profile PIN. Keep it somewhere safe; there is no device-code or biometric fallback.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                if let error = authentication.error { Text(error).foregroundStyle(.red) }
                Button(prompt.isSetup ? "Create Admin Code" : "Unlock") {
                    editing = false
                    let submitted = code, repeated = confirmation
                    code = ""; confirmation = ""
                    authentication.submit(code: submitted, confirmation: repeated)
                }
                .disabled(authentication.verifying || !AdminCodeStore.isValidCode(code) ||
                          (prompt.isSetup && code != confirmation))
                if authentication.verifying { ProgressView("Checking admin code…") }
            }
            .navigationTitle(prompt.isSetup ? "Set Up Admin" : "Admin Authorization")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { authentication.cancel() }
                }
            }
            .onDisappear { code = ""; confirmation = "" }
        }
    }
}
