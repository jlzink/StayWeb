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
