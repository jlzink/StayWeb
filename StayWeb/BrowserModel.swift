import SwiftUI
import WebKit

@MainActor
final class BrowserModel: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate {
    @Published var address = ""
    @Published var title = "StayWeb"
    @Published var progress = 0.0
    @Published var loading = false
    @Published var canBack = false
    @Published var canForward = false
    @Published var ready = false
    @Published var notice: String?
    @Published var blockerStatus = "Preparing ad blocker…"
    @Published var currentSettings = SiteSettings()
    @Published var currentHost = ""
    @Published var blockedAppLinks = 0
    var openNewTab: ((URL) -> Void)?
    let webView: WKWebView
    @Published var filterVersion = "Not loaded"
    private var activeRuleCount = 0
    private var streamingScript: String?
    private var ruleList: WKContentRuleList?
    private var observations: [NSKeyValueObservation] = []
    private var settings: [String: SiteSettings] = [:]
    private var started = false
    private var disneyGate = DisneyGateRecovery()
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: "siteSettings"),
           let saved = try? JSONDecoder().decode([String: SiteSettings].self, from: data) {
            settings = saved
        }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.allowsInlineMediaPlayback = true
        configuration.allowsPictureInPictureMediaPlayback = true
        configuration.allowsAirPlayForMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        configuration.defaultWebpagePreferences.preferredContentMode = .desktop
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        // WebKit disables the element Fullscreen API by default. Players such
        // as YouTube use it for their entire player, not just the video element.
        configuration.preferences.isElementFullscreenEnabled = true
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        observations = [
            webView.observe(\.url, options: [.new]) { [weak self] _, _ in
                Task { @MainActor in self?.locationChanged() }
            },
            webView.observe(\.estimatedProgress, options: [.new]) { [weak self] _, _ in
                Task { @MainActor in self?.sync() }
            },
            webView.observe(\.isLoading, options: [.new]) { [weak self] _, _ in
                Task { @MainActor in self?.sync() }
            },
            webView.observe(\.canGoBack, options: [.new]) { [weak self] _, _ in
                Task { @MainActor in self?.sync() }
            },
            webView.observe(\.canGoForward, options: [.new]) { [weak self] _, _ in
                Task { @MainActor in self?.sync() }
            }
        ]
    }

    func start() async {
        guard !started else { return }
        started = true
        do {
            guard let url = Bundle.main.url(forResource: "blocker", withExtension: "json") else {
                throw NSError(domain: "StayWeb", code: 1, userInfo: [NSLocalizedDescriptionKey: "Missing blocker rules."])
            }
            let metadataURL = Bundle.main.url(forResource: "filter-info", withExtension: "json")!
            let metadata = try JSONSerialization.jsonObject(with: Data(contentsOf: metadataURL)) as? [String: Any]
            guard metadata?["prepared"] as? Bool == true,
                  let count = metadata?["ruleCount"] as? Int, count > 1000 else {
                throw NSError(domain: "StayWeb", code: 2, userInfo: [NSLocalizedDescriptionKey: "Build filters were not prepared."])
            }
            activeRuleCount = count
            filterVersion = metadata?["version"] as? String ?? "Unknown"
            if let scriptURL = Bundle.main.url(forResource: "StreamingFilter", withExtension: "js") {
                streamingScript = try String(contentsOf: scriptURL, encoding: .utf8)
            }
            let json = try String(contentsOf: url, encoding: .utf8)
            ruleList = try await WKContentRuleListStore.default().compileContentRuleList(
                forIdentifier: "StayWeb-Ultimate-" + filterVersion, encodedContentRuleList: json)
            blockerStatus = "\(activeRuleCount) rules ready"
        } catch {
            blockerStatus = "Ad blocker unavailable"
            notice = "Ad blocking could not start: \(error.localizedDescription)"
        }
        ready = true
    }

    func reuseProtection(from source: BrowserModel) {
        guard !started else { return }
        started = true
        ruleList = source.ruleList
        streamingScript = source.streamingScript
        activeRuleCount = source.activeRuleCount
        filterVersion = source.filterVersion
        blockerStatus = ruleList == nil ? "Ad blocker unavailable" : "\(activeRuleCount) rules ready"
        ready = true
    }

    func refreshSettings() {
        if let data = defaults.data(forKey: "siteSettings"),
           let saved = try? JSONDecoder().decode([String: SiteSettings].self, from: data) {
            settings = saved
        }
        if let url = webView.url { currentSettings = preferences(for: url) }
    }

    private func sync() {
        progress = webView.estimatedProgress
        loading = webView.isLoading
        canBack = webView.canGoBack
        canForward = webView.canGoForward
    }

    private func preferences(for url: URL) -> SiteSettings {
        // Read the shared store so other tabs immediately honor saved site choices.
        if let data = defaults.data(forKey: "siteSettings"),
           let saved = try? JSONDecoder().decode([String: SiteSettings].self, from: data) {
            settings = saved
        }
        return settings[url.host?.lowercased() ?? ""] ?? SiteSettings()
    }

    private func apply(_ value: SiteSettings) {
        let controller = webView.configuration.userContentController
        controller.removeAllContentRuleLists()
        if value.blockAds, let ruleList { controller.add(ruleList) }
        blockerStatus = !value.blockAds ? "Off for this site" : (ruleList == nil ? "Ad blocker unavailable" : "\(activeRuleCount) rules active")
    }

    private func wantsDisneyCompatibility(_ url: URL) -> Bool {
        let value = preferences(for: url)
        return BrowserPolicy.isDisney(url) && value.desktop && value.disneyCompatibility
    }

    private func wantsDesktopCompatibility(_ url: URL) -> Bool {
        let value = preferences(for: url)
        guard url.scheme == "https", value.desktop,
              BrowserPolicy.streamingService(url.host ?? "") != nil else { return false }
        return !BrowserPolicy.matches(url.host ?? "", domain: "disneyplus.com") || value.disneyCompatibility
    }

    private func prepareIdentity(for url: URL) {
        let compatible = wantsDesktopCompatibility(url)
        webView.customUserAgent = compatible ? BrowserPolicy.desktopSafariAgent : nil
        let controller = webView.configuration.userContentController
        controller.removeAllUserScripts()
        let value = preferences(for: url)
        if BrowserPolicy.streamingService(url.host ?? "") != nil,
           value.blockAds && value.streamingFilter, let streamingScript {
            controller.addUserScript(WKUserScript(source: streamingScript, injectionTime: .atDocumentStart,
                                                  forMainFrameOnly: true, in: .page))
        }
        if compatible {
            // Only modify top-level supported streaming documents.
            // This is device-detection compatibility, not a media-capability polyfill.
            let script = """
            (() => {
              if (location.protocol !== 'https:' ||
                  !['disneyplus.com', 'primevideo.com', 'hulu.com', 'peacocktv.com'].some(d => location.hostname === d || location.hostname.endsWith('.' + d))) return;
              for (const [key, value] of [['platform', 'MacIntel'], ['maxTouchPoints', 0]]) {
                try { Object.defineProperty(navigator, key, {get: () => value, configurable: true}); }
                catch (_) {}
              }
            })();
            """
            controller.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentStart,
                                                  forMainFrameOnly: true, in: .page))
        }
    }

    private func locationChanged() {
        guard let url = webView.url else { return }
        address = url.absoluteString
        currentHost = url.host?.lowercased() ?? ""
        currentSettings = preferences(for: url)
        // Also catch History API / SPA transitions, which may not invoke navigation policy.
        if !webView.isLoading, wantsDisneyCompatibility(url), BrowserPolicy.disneyWebHome(for: url) != nil {
            if let destination = disneyGate.destination(for: url) {
                notice = "Trying Disney+ web home with desktop compatibility."
                prepareIdentity(for: destination)
                webView.load(URLRequest(url: destination))
            } else {
                notice = "Disney+ still returned to its app-download page. Automatic retries stopped; playback is not yet working."
            }
        }
    }

    func reload() {
        disneyGate.reset()
        if let url = webView.url {
            prepareIdentity(for: url)
            if wantsDisneyCompatibility(url), let home = disneyGate.destination(for: url) {
                webView.load(URLRequest(url: home))
                return
            }
        }
        webView.reload()
    }

    func navigate(_ input: String) {
        guard ready, let url = BrowserPolicy.address(input) else { return }
        notice = nil
        disneyGate.reset()
        prepareIdentity(for: url)
        webView.load(URLRequest(url: url))
    }

    func saveSettings(_ value: SiteSettings) {
        guard !currentHost.isEmpty else { return }
        refreshSettings()
        settings[currentHost] = value
        if let data = try? JSONEncoder().encode(settings) { defaults.set(data, forKey: "siteSettings") }
        currentSettings = value
        apply(value)
        reload()
    }

    func clearData() async {
        webView.stopLoading()
        await webView.configuration.websiteDataStore.removeData(
            ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
        notice = "Cookies, cache and website storage cleared. Websites will require login again."
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 preferences: WKWebpagePreferences,
                 decisionHandler: @escaping (WKNavigationActionPolicy, WKWebpagePreferences) -> Void) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.cancel, preferences); return
        }
        let scheme = url.scheme?.lowercased() ?? ""
        // Internal frames may use these schemes. Never turn them into external app launches.
        if ["about", "blob", "data"].contains(scheme) {
            decisionHandler(.allow, preferences); return
        }
        guard BrowserPolicy.isWeb(url) else {
            blockedAppLinks += 1
            notice = "Kept you in StayWeb: blocked an external \(scheme) link."
            decisionHandler(.cancel, preferences); return
        }
        // Use the source page's rule so a redirect cannot disable its own protection.
        let sourceSettings = webView.url.map { self.preferences(for: $0) } ?? currentSettings
        if sourceSettings.blockAppLinks && BrowserPolicy.isAppStore(url) {
            blockedAppLinks += 1
            notice = "Blocked an App Store redirect. Playback still depends on the website."
            decisionHandler(.cancel, preferences); return
        }
        if navigationAction.targetFrame == nil,
           navigationAction.navigationType == .linkActivated,
           (navigationAction.request.httpMethod ?? "GET") == "GET", let openNewTab {
            decisionHandler(.cancel, preferences)
            openNewTab(url)
            return
        }
        let isMainNavigation = navigationAction.targetFrame?.isMainFrame != false
        if isMainNavigation && wantsDisneyCompatibility(url), BrowserPolicy.disneyWebHome(for: url) != nil {
            if let destination = disneyGate.destination(for: url) {
                decisionHandler(.cancel, preferences)
                notice = "Trying Disney+ web home with desktop compatibility."
                prepareIdentity(for: destination)
                webView.load(URLRequest(url: destination))
                return
            }
            notice = "Disney+ still returned to its app-download page. Automatic retries stopped; playback is not yet working."
        }
        if isMainNavigation {
            let desiredAgent = wantsDesktopCompatibility(url) ? BrowserPolicy.desktopSafariAgent : nil
            let identityChanged = (webView.customUserAgent ?? "") != (desiredAgent ?? "")
            prepareIdentity(for: url)
            // Reissue GET only when changing identity so its first HTTP request carries it.
            // Never replay POST/authentication submissions.
            if identityChanged && (navigationAction.request.httpMethod ?? "GET") == "GET" {
                decisionHandler(.cancel, preferences)
                webView.load(navigationAction.request)
                return
            }
        }
        // Reload user-tapped web links ourselves to avoid the normal link-activation
        // path into installed apps. Only GET is replayed; preserve POST/form bodies.
        if navigationAction.navigationType == .linkActivated,
           (navigationAction.request.httpMethod ?? "GET") == "GET" {
            decisionHandler(.cancel, preferences)
            webView.load(navigationAction.request)
            return
        }
        if navigationAction.targetFrame?.isMainFrame != false {
            let value = self.preferences(for: url)
            preferences.preferredContentMode = value.desktop ? .desktop : .mobile
            apply(value)
        }
        decisionHandler(.allow, preferences)
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        address = webView.url?.absoluteString ?? address
        currentHost = webView.url?.host?.lowercased() ?? ""
        currentSettings = webView.url.map { preferences(for: $0) } ?? SiteSettings()
        sync()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        title = webView.title ?? "StayWeb"
        address = webView.url?.absoluteString ?? address
        sync()
        locationChanged()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        report(error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        report(error)
    }

    private func report(_ error: Error) {
        if (error as NSError).code != NSURLErrorCancelled {
            notice = error.localizedDescription
        }
        sync()
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        notice = "The website process stopped. Tap reload to try again."
        sync()
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        // Keep unsolicited popups blocked; tapped links can open a new protected tab.
        if navigationAction.targetFrame == nil, navigationAction.navigationType == .linkActivated {
            if let url = navigationAction.request.url, BrowserPolicy.isWeb(url),
               !BrowserPolicy.isAppStore(url), let openNewTab {
                openNewTab(url)
            } else { webView.load(navigationAction.request) }
        } else {
            notice = "Popup blocked. Some sign-in flows may require a same-tab login."
        }
        return nil
    }
}
