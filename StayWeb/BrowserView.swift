import SwiftUI
import WebKit

struct WebSurface: UIViewRepresentable {
    let webView: WKWebView
    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

struct BrowserView: View {
    @StateObject private var browser = BrowserModel()
    @State private var input = ""
    @State private var showSettings = false
    @State private var clearConfirmation = false
    @FocusState private var editingAddress: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "shield.lefthalf.filled").foregroundStyle(.teal)
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
                    else { browser.webView.reload() }
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
            ZStack {
                WebSurface(webView: browser.webView)
                if browser.address.isEmpty {
                    VStack(spacing: 20) {
                        Image(systemName: "globe.europe.africa.fill")
                            .font(.system(size: 64)).foregroundStyle(.teal)
                        Text("StayWeb").font(.largeTitle.bold())
                        Text("Your websites. In your browser.").foregroundStyle(.secondary)
                        Button("Open Disney+") { open("https://www.disneyplus.com/") }
                            .buttonStyle(.borderedProminent).tint(.teal)
                            .disabled(!browser.ready)
                        Text("Disney+ playback is experimental.\nDesktop mode cannot guarantee streaming support.")
                            .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        Text(browser.blockerStatus).font(.caption)
                    }.padding().frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color(uiColor: .systemBackground))
                }
            }
            HStack {
                Button { browser.webView.goBack() } label: { Image(systemName: "chevron.left") }
                    .disabled(!browser.canBack).accessibilityLabel("Back")
                Spacer()
                Button { browser.webView.goForward() } label: { Image(systemName: "chevron.right") }
                    .disabled(!browser.canForward).accessibilityLabel("Forward")
                Spacer()
                if let url = browser.webView.url {
                    ShareLink(item: url) { Image(systemName: "square.and.arrow.up") }
                } else {
                    Image(systemName: "square.and.arrow.up").foregroundStyle(.secondary)
                }
                Spacer()
                Button { showSettings = true } label: { Image(systemName: "slider.horizontal.3") }
                    .accessibilityLabel("Site settings")
            }.font(.title3).padding().background(.thinMaterial)
        }
        .task { await browser.start() }
        .onChange(of: browser.address) { newValue in
            if !editingAddress { input = newValue }
        }
        .sheet(isPresented: $showSettings) {
            NavigationStack {
                Form {
                    Section(browser.currentHost.isEmpty ? "Open a website to change its settings" : browser.currentHost) {
                        Toggle("Block ads and trackers", isOn: setting(\.blockAds))
                        Toggle("Request desktop website", isOn: setting(\.desktop))
                        Toggle("Block App Store redirects", isOn: setting(\.blockAppLinks))
                    }.disabled(browser.currentHost.isEmpty)
                    Section("Protection") {
                        LabeledContent("Ad blocker", value: browser.blockerStatus)
                        LabeledContent("App links blocked this session", value: "\(browser.blockedAppLinks)")
                        Text("External app schemes are always blocked. HTTP links stay in the browser where WebKit allows. Starter ad rules cover common networks, not every ad or streaming commercial.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    Section("Website data") {
                        Button("Clear cookies and cache", role: .destructive) { clearConfirmation = true }
                    }
                    Section("Prototype 0.1.0") {
                        Text("One tab • iPhone and iPad • iOS 16+")
                        Text("Desktop mode requests a desktop site; it does not turn iOS into macOS. No DRM bypass or guaranteed streaming compatibility. Site-specific app-prompt removal is not included until validated selectors are available.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                .navigationTitle("StayWeb Settings")
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showSettings = false } } }
                .confirmationDialog("Clear all website data? This signs you out of websites.", isPresented: $clearConfirmation, titleVisibility: .visible) {
                    Button("Clear website data", role: .destructive) { Task { await browser.clearData() } }
                }
            }
        }
    }

    private func open(_ value: String) {
        editingAddress = false
        browser.navigate(value)
    }

    private func setting(_ key: WritableKeyPath<SiteSettings, Bool>) -> Binding<Bool> {
        Binding(get: { browser.currentSettings[keyPath: key] }, set: { value in
            var updated = browser.currentSettings
            updated[keyPath: key] = value
            browser.saveSettings(updated)
        })
    }
}
