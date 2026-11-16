import SwiftUI

struct KioskRootView: View {
    @ObservedObject var kiosk: KioskController
    @ObservedObject var admin: AdminCodeAuthenticator
    @ObservedObject private var profiles: ProfileStore
    @State private var selectedProfile: StayWebProfile?

    init(kiosk: KioskController, admin: AdminCodeAuthenticator) {
        self.kiosk = kiosk
        self.admin = admin
        profiles = kiosk.profiles
    }

    var body: some View {
        Group {
            if let prompt = admin.prompt {
                AdminCodePromptView(authentication: admin, prompt: prompt).id(prompt.id)
            } else if kiosk.ownerPanelPresented {
                KioskOwnerView(kiosk: kiosk, profiles: profiles, admin: admin)
            } else if let tabs = kiosk.browser {
                BrowserView(tabs: tabs,
                            onKiosk: { Task { await kiosk.openOwnerControls() } },
                            onLock: kiosk.enabled ? { kiosk.lockSession() } : nil)
                    .id(tabs.context.id)
            } else {
                profileChooser
            }
        }
        .overlay {
            if kiosk.privacyCovered {
                Color(uiColor: .systemBackground).ignoresSafeArea()
                    .overlay { Label("StayWeb is locked", systemImage: "lock.shield.fill").font(.title2) }
            }
        }
        .task { await kiosk.start() }
        .sheet(item: $selectedProfile) { profile in
            ProfileLoginView(profile: profile, kiosk: kiosk)
        }
        .safeAreaInset(edge: .bottom) {
            if !kiosk.enabled, !kiosk.ownerPanelPresented, admin.prompt == nil, let message = kiosk.message {
                HStack {
                    Text(message).font(.footnote)
                    Spacer()
                    Button { kiosk.message = nil } label: { Image(systemName: "xmark.circle") }
                        .accessibilityLabel("Dismiss status")
                }.padding(12).background(.regularMaterial)
            }
        }
        .onChange(of: kiosk.lockActive) { active in if !active { selectedProfile = nil } }
        .onChange(of: kiosk.privacyCovered) { covered in if covered { selectedProfile = nil } }
    }

    private var profileChooser: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    HStack(spacing: 18) {
                        Image("StayWebMark").resizable().scaledToFit().frame(width: 78, height: 78)
                            .clipShape(RoundedRectangle(cornerRadius: 20))
                        VStack(alignment: .leading, spacing: 5) {
                            Text("StayWeb").font(.largeTitle.bold())
                            Text("Choose your space").font(.title3).foregroundStyle(.secondary)
                        }
                    }
                    Label(kiosk.lockActive ? "Device kiosk lock is active" : "Waiting for the device kiosk lock",
                          systemImage: kiosk.lockActive ? "lock.shield.fill" : "lock.open.trianglebadge.exclamationmark")
                        .font(.headline).foregroundStyle(kiosk.lockActive ? Color.teal : Color.orange)
                    if !kiosk.guestProfilesSupported {
                        Text("Kiosk profiles require iOS or iPadOS 18.4 or newer. Owner browsing is still available after leaving kiosk mode.")
                    } else if !kiosk.lockActive {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Open Settings → Accessibility → Guided Access to configure it. Then return here and use the accessibility shortcut to start a session.")
                            Text("For a code-only exit, turn off Face ID and Touch ID in Guided Access settings. Its passcode is configured separately from the device unlock code.")
                                .font(.footnote).foregroundStyle(.secondary)
                            if kiosk.method == .managedAutomatic {
                                Button("Try managed lock again") { Task { await kiosk.startAutomaticLock() } }
                                    .buttonStyle(.bordered).disabled(kiosk.busy)
                            }
                        }
                    }
                    if let error = profiles.loadError { Text(error).foregroundStyle(.red) }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 16)], spacing: 16) {
                        ForEach(Array(profiles.profiles.enumerated()), id: \.element.id) { index, profile in
                            Button { selectedProfile = profile } label: {
                                VStack(alignment: .leading, spacing: 24) {
                                    Image(systemName: "person.crop.circle.fill").font(.system(size: 44))
                                    Text(profile.name).font(.title2.bold()).lineLimit(2)
                                    Label("Enter your PIN", systemImage: "lock.fill").font(.subheadline)
                                }
                                .foregroundStyle(.white)
                                .frame(maxWidth: .infinity, minHeight: 170, alignment: .leading)
                                .padding(24)
                                .background(LinearGradient(colors: profileColors(index), startPoint: .topLeading,
                                                           endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 24))
                            }
                            .buttonStyle(.plain)
                            .disabled(!kiosk.canStartGuest || profiles.loadError != nil)
                        }
                    }
                    if profiles.profiles.isEmpty {
                        Text("Use Owner Controls to add a user.").foregroundStyle(.secondary)
                    }
                    if let message = kiosk.message { Text(message).font(.callout).foregroundStyle(.secondary) }
                    if kiosk.busy { ProgressView("Please wait…") }
                    Text("Each profile has separate website logins, website data, shortcuts, and site settings. These are StayWeb profiles; device services remain shared by iPadOS.")
                        .font(.footnote).foregroundStyle(.secondary)
                }.padding(24).frame(maxWidth: 900).frame(maxWidth: .infinity)
            }
            .navigationTitle("Kiosk")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { Task { await kiosk.openOwnerControls() } } label: {
                        Label("Owner Controls", systemImage: "person.badge.key.fill")
                    }.disabled(kiosk.busy)
                }
            }
        }
    }

    private func profileColors(_ index: Int) -> [Color] {
        let palettes: [[Color]] = [[.teal, .blue], [.indigo, .purple], [.orange, .pink], [.blue, .indigo]]
        return palettes[index % palettes.count]
    }
}

private struct ProfileLoginView: View {
    let profile: StayWebProfile
    @ObservedObject var kiosk: KioskController
    @Environment(\.dismiss) private var dismiss
    @State private var pin = ""
    @State private var signInTask: Task<Void, Never>?
    @FocusState private var pinFocused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section("Sign in to \(profile.name)") {
                    SecureField("Profile PIN", text: $pin)
                        .keyboardType(.numberPad).focused($pinFocused).privacySensitive()
                    Text("Use this person's StayWeb PIN, separate from the admin code.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if let message = kiosk.message { Section { Text(message).foregroundStyle(.secondary) } }
                Button("Sign In") {
                    pinFocused = false
                    let submittedPIN = pin
                    pin = ""
                    signInTask = Task { if await kiosk.signIn(profile: profile, pin: submittedPIN) { dismiss() } }
                }.disabled(kiosk.busy || !kiosk.canStartGuest || !ProfileStore.isValidPIN(pin))
                if kiosk.busy { ProgressView() }
            }
            .navigationTitle("\(profile.name)")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { signInTask?.cancel(); pin = ""; dismiss() } } }
            .onDisappear { signInTask?.cancel(); pin = "" }
        }
        .presentationDetents([.medium, .large])
    }
}

private struct KioskOwnerView: View {
    @ObservedObject var kiosk: KioskController
    @ObservedObject var profiles: ProfileStore
    @ObservedObject var admin: AdminCodeAuthenticator
    @State private var adding = false
    @State private var editing: StayWebProfile?
    @State private var changingAdminCode = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Kiosk") {
                    LabeledContent("Mode", value: kiosk.enabled ? "Enabled" : "Off")
                    LabeledContent("System lock", value: kiosk.lockActive ? "Active" : "Not active")
                    Picker("Lock method", selection: Binding(get: { kiosk.method }, set: { kiosk.setMethod($0) })) {
                        ForEach(KioskLockMethod.allCases) { method in Text(method.title).tag(method) }
                    }.disabled(kiosk.enabled || kiosk.busy)
                    if kiosk.method == .guidedAccess {
                        Text("You start and end Guided Access with the device's accessibility shortcut. Configure its exit passcode in Settings. Disable its biometric exit options if a code must always be entered.")
                            .font(.footnote).foregroundStyle(.secondary)
                    } else {
                        Text("Requires a supervised device and MDM authorization for StayWeb's Autonomous Single App Mode. A developer membership alone does not grant that permission.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    if kiosk.enabled {
                        Button("End Kiosk", role: .destructive) { Task { await kiosk.endKiosk() } }
                            .disabled(kiosk.busy)
                        Text("Leaving kiosk mode requires a fresh StayWeb admin-code check. A lock imposed by Guided Access or management software must be ended through that system.")
                            .font(.footnote).foregroundStyle(.secondary)
                    } else {
                        Button("Start Kiosk") { Task { await kiosk.enableKiosk() } }
                            .disabled(!kiosk.guestProfilesSupported || profiles.profiles.isEmpty || profiles.loadError != nil || kiosk.busy)
                    }
                }
                Section("StayWeb users") {
                    ForEach(profiles.profiles) { profile in
                        Button { editing = profile } label: {
                            HStack { Label(profile.name, systemImage: "person.crop.circle"); Spacer(); Text("Edit").foregroundStyle(.secondary) }
                        }
                    }
                    Button { adding = true } label: { Label("Add User", systemImage: "person.badge.plus") }
                        .disabled(profiles.loadError != nil || kiosk.busy)
                    if let error = profiles.loadError { Text(error).foregroundStyle(.red) }
                }
                Section("Owner protection") {
                    Button("Change Admin Code") { changingAdminCode = true }.disabled(kiosk.busy)
                    Text("The StayWeb admin code protects these controls and is separate from the device unlock code. User PINs protect each StayWeb profile separately. There is no device-code or biometric fallback.")
                    Text("File uploads, camera, and microphone access are blocked for guest websites. The Share button, AirPlay, and Picture in Picture are unavailable in guest profiles.")
                    Text("Website data is separate. System Password AutoFill, passkeys, keyboards, and the clipboard belong to the device and are not separate user accounts.")
                    if !kiosk.guestProfilesSupported {
                        Text("Update to iOS or iPadOS 18.4 or newer to enable protected kiosk profiles.").foregroundStyle(.orange)
                    }
                }.font(.footnote)
                if let message = kiosk.message { Section { Text(message).foregroundStyle(.secondary) } }
                if kiosk.busy { ProgressView("Checking admin authorization…") }
            }
            .navigationTitle("Owner Controls")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { kiosk.closeOwnerControls() }.disabled(kiosk.busy) } }
            .sheet(isPresented: $adding) { ProfileEditorView(profiles: profiles, profile: nil) }
            .sheet(item: $editing) { profile in ProfileEditorView(profiles: profiles, profile: profile) }
            .sheet(isPresented: $changingAdminCode) { AdminCodeChangeView(codes: admin.codes) }
            .interactiveDismissDisabled(kiosk.busy)
        }
    }
}

private struct ProfileEditorView: View {
    @ObservedObject var profiles: ProfileStore
    let profile: StayWebProfile?
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var pin = ""
    @State private var confirmation = ""
    @State private var saving = false
    @State private var saveTask: Task<Void, Never>?
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Profile") { TextField("Name", text: $name).textContentType(.nickname) }
                Section(profile == nil ? "Profile PIN" : "Change PIN (optional)") {
                    SecureField("At least 6 digits", text: $pin).keyboardType(.numberPad).privacySensitive()
                    SecureField("Confirm PIN", text: $confirmation).keyboardType(.numberPad).privacySensitive()
                    Text("Choose a separate PIN for this user. The owner can reset it here after entering the StayWeb admin code.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if let error { Text(error).foregroundStyle(.red) }
                if saving { ProgressView("Saving profile…") }
            }
            .navigationTitle(profile == nil ? "Add User" : "Edit User")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(saving) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { saveTask = Task { await save() } }.disabled(saving || !valid)
                }
            }
            .interactiveDismissDisabled(saving)
            .onAppear { name = profile?.name ?? "" }
            .onDisappear { saveTask?.cancel(); pin = ""; confirmation = "" }
        }
    }

    private var valid: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        ((profile != nil && pin.isEmpty && confirmation.isEmpty) ||
         (ProfileStore.isValidPIN(pin) && pin == confirmation))
    }

    @MainActor
    private func save() async {
        guard valid else { return }
        saving = true
        defer { saving = false; pin = ""; confirmation = "" }
        do {
            if let profile {
                try await profiles.updateProfile(profileID: profile.id, name: name, pin: pin.isEmpty ? nil : pin)
            } else { _ = try await profiles.createProfile(name: name, pin: pin) }
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}

private struct AdminCodeChangeView: View {
    @ObservedObject var codes: AdminCodeStore
    @Environment(\.dismiss) private var dismiss
    @State private var current = ""
    @State private var replacement = ""
    @State private var confirmation = ""
    @State private var saving = false
    @State private var problem: String?
    @State private var saveTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            Form {
                Section("Current admin code") {
                    SecureField("Current code", text: $current).keyboardType(.numberPad).privacySensitive()
                }
                Section("New admin code") {
                    SecureField("6–32 digits", text: $replacement).keyboardType(.numberPad).privacySensitive()
                    SecureField("Confirm new code", text: $confirmation).keyboardType(.numberPad).privacySensitive()
                    Text("Changing this code does not change the iPad unlock code or the Guided Access exit passcode in Settings.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if let problem { Text(problem).foregroundStyle(.red) }
                if saving { ProgressView("Updating admin code…") }
            }
            .navigationTitle("Change Admin Code")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { saveTask?.cancel(); dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        saving = true
                        saveTask = Task {
                            defer { saving = false; current = ""; replacement = ""; confirmation = "" }
                            do {
                                try await codes.changeCode(currentCode: current, newCode: replacement)
                                if !Task.isCancelled { dismiss() }
                            } catch { problem = error.localizedDescription }
                        }
                    }.disabled(saving || !AdminCodeStore.isValidCode(current) ||
                               !AdminCodeStore.isValidCode(replacement) || replacement != confirmation)
                }
            }
            .onDisappear {
                saveTask?.cancel()
                current = ""; replacement = ""; confirmation = ""
            }
        }
    }
}
