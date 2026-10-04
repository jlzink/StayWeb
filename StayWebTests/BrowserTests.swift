import XCTest
import WebKit
@testable import StayWeb

final class BrowserTests: XCTestCase {
    func testStoreRedirectBoundaries() throws {
        for value in ["https://apps.apple.com/us/app/id123", "https://itunes.apple.com/app/id123", "https://apps.apple.com./id123"] {
            XCTAssertTrue(BrowserPolicy.isAppStore(try XCTUnwrap(URL(string: value))))
        }
        for value in ["https://apps.apple.com.evil.example/", "https://notapps.apple.com/", "https://example.com/apps.apple.com"] {
            XCTAssertFalse(BrowserPolicy.isAppStore(try XCTUnwrap(URL(string: value))))
        }
    }

    func testDisneyGateRecoveryIsScopedAndBounded() throws {
        var recovery = DisneyGateRecovery()
        let gate = try XCTUnwrap(URL(string: "https://www.disneyplus.com/get-app?token=private#test"))
        XCTAssertEqual(recovery.destination(for: gate)?.absoluteString, "https://www.disneyplus.com/home")
        XCTAssertNil(recovery.destination(for: gate), "Must stop instead of looping")
        recovery.reset()
        XCTAssertNotNil(recovery.destination(for: gate))
        XCTAssertEqual(BrowserPolicy.disneyWebHome(for: URL(string: "https://www.disneyplus.com/en-us/get-app/")!)?.path, "/en-us/home")
        for value in ["https://www.disneyplus.com.evil.example/get-app",
                      "https://help.disneyplus.com/get-app", "https://example.com/get-app",
                      "http://www.disneyplus.com/get-app", "https://www.disneyplus.com/login",
                      "https://www.disneyplus.com/arbitrary/get-app", "https://www.disneyplus.com/a/b/get-app"] {
            XCTAssertNil(BrowserPolicy.disneyWebHome(for: URL(string: value)!))
        }
    }

    func testOldSettingsKeepUserChoices() throws {
        let data = Data(#"{"blockAds":false,"desktop":false,"blockAppLinks":false}"#.utf8)
        let decoded = try JSONDecoder().decode(SiteSettings.self, from: data)
        XCTAssertFalse(decoded.blockAds)
        XCTAssertFalse(decoded.desktop)
        XCTAssertFalse(decoded.blockAppLinks)
        XCTAssertTrue(decoded.disneyCompatibility)
        XCTAssertTrue(decoded.streamingFilter)
        XCTAssertEqual(try JSONDecoder().decode(SiteSettings.self, from: JSONEncoder().encode(decoded)), decoded)
    }

    @MainActor
    func testDisneyIdentityIsSetBeforeLoadAndRemovedOffSite() async throws {
        let domain = "StayWebTests-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let model = BrowserModel(defaults: defaults)
        await model.start()
        model.navigate("https://www.disneyplus.com/")
        XCTAssertEqual(model.webView.customUserAgent, BrowserPolicy.desktopSafariAgent)
        XCTAssertEqual(model.webView.configuration.userContentController.userScripts.count, 2)
        model.webView.stopLoading()
        model.navigate("https://example.com/")
        XCTAssertEqual(model.webView.customUserAgent ?? "", "")
        XCTAssertTrue(model.webView.configuration.userContentController.userScripts.isEmpty)
        model.webView.stopLoading()
    }

    @MainActor
    func testNativeIdentityDoesNotReplayEveryGET() async {
        let model = BrowserModel()
        await model.start()
        let probe = PolicyProbe()
        probe.forward = model
        probe.cancelAllowedNavigation = true
        model.webView.navigationDelegate = probe
        let finished = expectation(description: "Native identity allows navigation without a reload loop")
        probe.onDecision = { policy in
            XCTAssertEqual(policy, .allow)
            finished.fulfill()
        }
        model.navigate("https://example.com/")
        await fulfillment(of: [finished], timeout: 10)
        model.webView.stopLoading()
    }

    func testAddressAndSearch() {
        XCTAssertEqual(BrowserPolicy.address(" disneyplus.com ")?.absoluteString, "https://disneyplus.com")
        XCTAssertEqual(BrowserPolicy.address("https://example.com/path?q=test")?.host, "example.com")
        XCTAssertEqual(BrowserPolicy.address("movies & television")?.host, "duckduckgo.com")
        XCTAssertNil(BrowserPolicy.address("  "))
        XCTAssertFalse(BrowserPolicy.isWeb(URL(string: "disneyplus://home")!))
        XCTAssertFalse(BrowserPolicy.isWeb(URL(string: "javascript:alert(1)")!))
    }

    @MainActor
    func testWebKitCompilesBundledRules() async throws {
        let bundle = Bundle(for: BrowserModel.self)
        let url = try XCTUnwrap(bundle.url(forResource: "blocker", withExtension: "json"))
        let json = try String(contentsOf: url, encoding: .utf8)
        let rule = try await WKContentRuleListStore.default().compileContentRuleList(
            forIdentifier: "StayWeb-Test-Rules", encodedContentRuleList: json)
        XCTAssertNotNil(rule)
    }

    @MainActor
    func testPrimeManifestFilteringWithRealWebKitXMLParser() async throws {
        let view = WKWebView()
        let url = try XCTUnwrap(Bundle(for: BrowserModel.self).url(forResource: "StreamingFilter", withExtension: "js"))
        let source = try String(contentsOf: url, encoding: .utf8)
        let script = """
        window.fixtureMPD = '<MPD mediaPresentationDuration="PT90S"><Period start="PT0S"><SupplementalProperty value="Ad"/><BaseURL>ad.mp4</BaseURL></Period><Period start="PT30S"><ContentProtection schemeIdUri="keep"/><BaseURL>movie.mp4</BaseURL></Period></MPD>';
        window.fetch = async () => new Response(window.fixtureMPD);
        (function(location) { \(source) })({protocol:'https:', hostname:'www.primevideo.com', href:'https://www.primevideo.com/'});
        const response = await fetch('https://media.example/movie.mpd');
        const text = await response.text();
        const doc = new DOMParser().parseFromString(text, 'application/xml');
        return doc.getElementsByTagName('Period').length === 1 &&
          doc.getElementsByTagName('ContentProtection').length === 1 &&
          text.includes('movie.mp4') && !text.includes('ad.mp4') &&
          !doc.documentElement.hasAttribute('mediaPresentationDuration');
        """
        let result = try await view.callAsyncJavaScript(script, arguments: [:], in: nil, contentWorld: .page)
        XCTAssertEqual(result as? Bool, true)
        let unchanged = try await view.callAsyncJavaScript("""
        // Malformed or all-ad manifests must remain untouched rather than empty.
        for (const source of ['<MPD><Period><Role value="Ad"/></Period></MPD>', '<MPD><Period><BaseURL>movie.mp4</BaseURL></Period></MPD>', '<MPD invalid']) {
          window.fixtureMPD = source;
          const r = await fetch('https://media.example/plain.mpd');
          if (await r.text() !== source) return false;
        }
        return true;
        """, arguments: [:], in: nil, contentWorld: .page)
        XCTAssertEqual(unchanged as? Bool, true)
    }

    @MainActor
    func testNavigationRejectsStore() async {
        let model = BrowserModel()
        await model.start()
        let store = PolicyProbe()
        model.webView.navigationDelegate = store
        // Test the actual model delegate using actions supplied by WebKit.
        store.forward = model
        let expectation = expectation(description: "Store navigation is cancelled")
        store.onDecision = { policy in
            XCTAssertEqual(policy, .cancel)
            expectation.fulfill()
        }
        model.webView.load(URLRequest(url: URL(string: "https://apps.apple.com/us/app/id123")!))
        await fulfillment(of: [expectation], timeout: 10)
        XCTAssertEqual(model.blockedAppLinks, 1)
    }
}

@MainActor
private final class PolicyProbe: NSObject, WKNavigationDelegate {
    var forward: BrowserModel?
    var cancelAllowedNavigation = false
    var onDecision: ((WKNavigationActionPolicy) -> Void)?
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 preferences: WKWebpagePreferences,
                 decisionHandler: @escaping (WKNavigationActionPolicy, WKWebpagePreferences) -> Void) {
        forward?.webView(webView, decidePolicyFor: action, preferences: preferences) { policy, prefs in
            decisionHandler(self.cancelAllowedNavigation ? .cancel : policy, prefs)
            let callback = self.onDecision
            self.onDecision = nil
            callback?(policy)
        }
    }
}
