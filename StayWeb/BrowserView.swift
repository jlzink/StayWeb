import SwiftUI
import WebKit

struct WebSurface: UIViewRepresentable {
    let webView: WKWebView
    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

struct BrowserView: View {
    @ObservedObject var tabs: TabStore
    let onKiosk: () -> Void
    let onLock: (() -> Void)?

    init(tabs: TabStore, onKiosk: @escaping () -> Void, onLock: (() -> Void)? = nil) {
        self.tabs = tabs
        self.onKiosk = onKiosk
        self.onLock = onLock
    }
    var body: some View {
        BrowserTabView(browser: tabs.selected.browser, tabs: tabs, onKiosk: onKiosk, onLock: onLock)
            .id(tabs.selectedID)
    }
}

struct BrowserTabView: View {
    @ObservedObject var browser: BrowserModel
    @ObservedObject var tabs: TabStore
    let onKiosk: () -> Void
    let onLock: (() -> Void)?
    @State private var showTabs = false
    @State private var showHome = false
    @State private var input = ""
    @State private var showSettings = false
    @State private var clearConfirmation = false
    @State private var pageFullscreen = false
    @FocusState private var editingAddress: Bool

    var body: some View {
        VStack(spacing: 0) {
            if !pageFullscreen {
                HStack(spacing: 10) {
                    Button(action: openOwnerControls) {
                        Image(systemName: "shield.lefthalf.filled").foregroundStyle(.teal)
                    }.accessibilityLabel("Kiosk owner controls")
                    TextField("Search or enter website", text: $input)
                        .keyboardType(.webSearch)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.go)
                        .focused($editingAddress)
                        .onSubmit { open(input) }
                        .accessibilityLabel("Website address or search")
                    Button {
                        if browser.loading { browser.webView.stopLoading() }
                        else { browser.reload() }
                    } label: {
                        Image(systemName: browser.loading ? "xmark" : "arrow.clockwise")
                    }.accessibilityLabel(browser.loading ? "Stop loading" : "Reload")
                }
                .padding(12).background(.thinMaterial)
                ProgressView(value: browser.progress).opacity(browser.loading ? 1 : 0)
                if let notice = browser.notice {
                    HStack(alignment: .top) {
                        Text(notice).font(.caption)
                        Spacer()
                        Button { browser.notice = nil } label: { Image(systemName: "xmark.circle") }
                            .accessibilityLabel("Dismiss notice")
                    }.padding(10).background(Color.orange.opacity(0.14))
                }
            }
            ZStack {
                WebSurface(webView: browser.webView)
                    .ignoresSafeArea(.container, edges: pageFullscreen ? .all : [])
                if browser.address.isEmpty || showHome {
                    StreamingHome(ready: browser.ready, defaults: tabs.context.defaults, open: open, openInNewTab: { tabs.add($0) })
                }
            }

            if !pageFullscreen {
                HStack {
                    Button { showHome = false; browser.webView.goBack() } label: { Image(systemName: "chevron.left") }
                        .disabled(!browser.canBack).accessibilityLabel("Back")
                    Spacer()
                    Button { showHome = false; browser.webView.goForward() } label: { Image(systemName: "chevron.right") }
                        .disabled(!browser.canForward).accessibilityLabel("Forward")
                    Spacer()
                    Button { editingAddress = false; showHome.toggle() } label: { Image(systemName: "house") }
                        .accessibilityLabel("Streaming home")
                    Spacer()
                    if tabs.context.isGuest, let onLock {
                        Button(action: onLock) { Image(systemName: "person.crop.circle.badge.checkmark") }
                            .accessibilityLabel("Lock profile and switch user")
                    } else if !tabs.context.isGuest, let url = browser.webView.url {
                        ShareLink(item: url) { Image(systemName: "square.and.arrow.up") }
                    } else {
                        Image(systemName: "square.and.arrow.up").foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button { editingAddress = false; showTabs = true } label: {
                        ZStack {
                            Image(systemName: "square.on.square")
                            Text("\(tabs.tabs.count)").font(.system(size: 9, weight: .bold)).offset(x: 2, y: 2)
                        }
                    }.accessibilityLabel("Tabs, \(tabs.tabs.count) open")
                    Spacer()
                    Button {
                        editingAddress = false
                        pageFullscreen = true
                    } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                        .disabled(browser.address.isEmpty || showHome)
                        .accessibilityLabel("Fullscreen website")
                    Spacer()
                    Button { showSettings = true } label: { Image(systemName: "slider.horizontal.3") }
                        .accessibilityLabel("Site settings")
                }.font(.title3).padding().background(.thinMaterial)
            }
        }
        .overlay(alignment: .topTrailing) {
            if pageFullscreen {
                Button { pageFullscreen = false } label: {
                    Image(systemName: "arrow.down.right.and.arrow.up.left")
                        .font(.title3.weight(.semibold))
                        .frame(width: 44, height: 44)
                        .background(.regularMaterial, in: Circle())
                }
                .padding(12)
                .accessibilityLabel("Exit fullscreen website")
            }
        }
        .statusBarHidden(pageFullscreen)
        .persistentSystemOverlays(pageFullscreen ? .hidden : .automatic)
        .task { input = browser.address; await tabs.prepare(browser) }
        .sheet(isPresented: $showTabs) { TabSwitcher(tabs: tabs) }
        .onChange(of: browser.address) { newValue in
            if !editingAddress { input = newValue }
        }
        .sheet(isPresented: $showSettings) {
            NavigationStack {
                Form {
                    Section(browser.currentHost.isEmpty ? "Open a website to change its settings" : browser.currentHost) {
                        Toggle("Block ads and trackers", isOn: setting(\.blockAds))
                        if let service = BrowserPolicy.streamingService(browser.currentHost) {
                            Toggle("\(service) streaming filter", isOn: setting(\.streamingFilter))
                            Text("Experimental playback filtering. Requires ad blocking. Turn off if playback fails; changing this setting reloads the page.")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                        Toggle("Request desktop website", isOn: setting(\.desktop))
                        if tabs.context.isGuest {
                            Label("App Store redirects are blocked in kiosk profiles", systemImage: "lock.fill")
                                .font(.footnote)
                        } else {
                            Toggle("Block App Store redirects", isOn: setting(\.blockAppLinks))
                        }
                        if browser.currentHost == "www.disneyplus.com" || browser.currentHost == "disneyplus.com" {
                            Toggle("Disney+ desktop compatibility", isOn: setting(\.disneyCompatibility))
                            Text("Uses a desktop Safari identity and tries web home once if Disney+ sends you to its download page. Requires desktop mode. Playback remains experimental.")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }.disabled(browser.currentHost.isEmpty)
                    Section("Protection") {
                        LabeledContent("Ad blocker", value: browser.blockerStatus)
                        LabeledContent("Filter version", value: browser.filterVersion)
                        LabeledContent("App links blocked this session", value: "\(browser.blockedAppLinks)")
                        Text("External app schemes are always blocked. HTTP links stay in the browser where WebKit allows. Uses a snapshot of Ultimate Ad Filter converted for WebKit. Some advanced Chrome extension rules are unsupported. Streaming ad removal is experimental.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    Section("Filter credits") {
                        Text((try? String(contentsOf: Bundle.main.url(forResource: "FilterCredits", withExtension: "txt")!, encoding: .utf8)) ?? "AdBlocker Ultimate contributors")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    Section("Kiosk") {
                        Button("Owner controls", action: openOwnerControls)
                        if let onLock { Button("Lock profile and switch user", action: onLock) }
                        if tabs.context.isGuest {
                            Text("This profile has its own website logins, site settings and shortcuts. The Share button, uploads, downloads, camera, microphone, Picture in Picture and AirPlay are unavailable here.")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    Section("Website data") {
                        Button("Clear cookies and cache", role: .destructive) { clearConfirmation = true }
                    }
                    Section("StayWeb") {
                        Text("Multiple tabs • iPhone and iPad • Kiosk profiles on iOS 18.4+")
                        Text("Desktop mode requests a desktop site; it does not turn iOS into macOS. No DRM bypass or guaranteed streaming compatibility. Site-specific app-prompt removal is not included until validated selectors are available.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                .navigationTitle("StayWeb Settings")
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showSettings = false } } }
                .confirmationDialog("Clear this profile’s website data? This signs this profile out of websites.", isPresented: $clearConfirmation, titleVisibility: .visible) {
                    Button("Clear website data", role: .destructive) { Task { await tabs.clearData() } }
                }
            }
        }
    }

    private func open(_ value: String) {
        editingAddress = false
        showHome = false
        browser.navigate(value)
    }

    private func openOwnerControls() {
        editingAddress = false
        showSettings = false
        onKiosk()
    }

    private func setting(_ key: WritableKeyPath<SiteSettings, Bool>) -> Binding<Bool> {
        Binding(get: { browser.currentSettings[keyPath: key] }, set: { value in
            var updated = browser.currentSettings
            updated[keyPath: key] = value
            browser.saveSettings(updated)
        })
    }
}
