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
        XCTAssertEqual(model.webView.configuration.userContentController.userScripts.count, 1)
        model.webView.stopLoading()
        model.navigate("https://example.com/")
        XCTAssertNil(model.webView.customUserAgent)
        XCTAssertTrue(model.webView.configuration.userContentController.userScripts.isEmpty)
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
    var onDecision: ((WKNavigationActionPolicy) -> Void)?
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 preferences: WKWebpagePreferences,
                 decisionHandler: @escaping (WKNavigationActionPolicy, WKWebpagePreferences) -> Void) {
        forward?.webView(webView, decidePolicyFor: action, preferences: preferences) { policy, prefs in
            decisionHandler(policy, prefs)
            let callback = self.onDecision
            self.onDecision = nil
            callback?(policy)
        }
    }
}
