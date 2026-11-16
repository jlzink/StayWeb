import XCTest
import WebKit
@testable import StayWeb

final class KioskBrowserTests: XCTestCase {
    @MainActor
    func testOwnerKeepsTheExistingWebsiteStore() {
        let context = BrowserContext.owner
        XCTAssertFalse(context.isGuest)
        XCTAssertTrue(context.defaults === UserDefaults.standard)
        XCTAssertTrue(context.dataStore === WKWebsiteDataStore.default())
        let tabs = TabStore(context: context)
        XCTAssertTrue(tabs.selected.browser.webView.configuration.websiteDataStore === context.dataStore)
        XCTAssertTrue(tabs.selected.browser.webView.configuration.allowsPictureInPictureMediaPlayback)
        tabs.shutdown()
    }

    @MainActor
    func testProfileCookiesPersistWithoutCrossingIntoAnotherProfile() async throws {
        guard #available(iOS 18.4, *) else { throw XCTSkip("Guest profiles require iOS 18.4") }
        let firstID = UUID(), secondID = UUID()
        let first = try BrowserContext.guest(id: firstID)
        let second = try BrowserContext.guest(id: secondID)
        let name = "stayweb-fixture-" + UUID().uuidString
        let cookie = try XCTUnwrap(HTTPCookie(properties: [
            .domain: "stayweb-fixture.invalid", .path: "/", .name: name,
            .value: "first-profile-session", .expires: Date().addingTimeInterval(3600)
        ]))
        await first.dataStore.httpCookieStore.setCookie(cookie)
        let reopened = try BrowserContext.guest(id: firstID)
        let firstCookies = await reopened.dataStore.httpCookieStore.allCookies()
        let secondCookies = await second.dataStore.httpCookieStore.allCookies()
        let ownerCookies = await BrowserContext.owner.dataStore.httpCookieStore.allCookies()
        XCTAssertEqual(firstCookies.first(where: { $0.name == name })?.value, "first-profile-session")
        XCTAssertFalse(secondCookies.contains(where: { $0.name == name }))
        XCTAssertFalse(ownerCookies.contains(where: { $0.name == name }))
        XCTAssertEqual(first.dataStore.identifier, firstID)
        XCTAssertEqual(second.dataStore.identifier, secondID)
        await first.dataStore.httpCookieStore.deleteCookie(cookie)
    }

    @MainActor
    func testProfileTabsShareOnlyTheirOwnSettingsAndShortcuts() throws {
        guard #available(iOS 18.4, *) else { throw XCTSkip("Guest profiles require iOS 18.4") }
        let firstID = UUID(), secondID = UUID()
        let first = try BrowserContext.guest(id: firstID)
        let second = try BrowserContext.guest(id: secondID)
        defer {
            first.defaults.removePersistentDomain(forName: BrowserContext.preferencesDomain(for: firstID))
            second.defaults.removePersistentDomain(forName: BrowserContext.preferencesDomain(for: secondID))
        }
        let tabs = TabStore(context: first)
        defer { tabs.shutdown() }
        let added = tabs.add()
        XCTAssertTrue(added.browser.webView.configuration.websiteDataStore === first.dataStore)
        XCTAssertFalse(added.browser.webView.configuration.websiteDataStore === second.dataStore)
        first.defaults.set(Data("first only".utf8), forKey: "streamingShortcuts")
        XCTAssertNil(second.defaults.data(forKey: "streamingShortcuts"))
        XCTAssertEqual(try BrowserContext.guest(id: firstID).defaults.data(forKey: "streamingShortcuts"),
                       Data("first only".utf8))

        let model = tabs.selected.browser
        model.currentHost = "example.com"
        var settings = SiteSettings()
        settings.blockAds = false
        settings.blockAppLinks = false
        model.saveSettings(settings)
        let data = try XCTUnwrap(first.defaults.data(forKey: "siteSettings"))
        let saved = try JSONDecoder().decode([String: SiteSettings].self, from: data)
        XCTAssertFalse(try XCTUnwrap(saved["example.com"]).blockAds)
        XCTAssertTrue(try XCTUnwrap(saved["example.com"]).blockAppLinks,
                      "Guests cannot weaken mandatory app-link blocking")
        XCTAssertNil(second.defaults.data(forKey: "siteSettings"))
    }

    @MainActor
    func testGuestDisablesMediaHandoffsAndLinkPreview() throws {
        guard #available(iOS 18.4, *) else { throw XCTSkip("Guest profiles require iOS 18.4") }
        let model = BrowserModel(context: try .guest(id: UUID()))
        defer { model.shutdown() }
        XCTAssertFalse(model.webView.configuration.allowsPictureInPictureMediaPlayback)
        XCTAssertFalse(model.webView.configuration.allowsAirPlayForMediaPlayback)
        XCTAssertFalse(model.webView.allowsLinkPreview)
        XCTAssertTrue(model.webView.uiDelegate !== model)
        XCTAssertFalse(model.webView.configuration.preferences.javaScriptCanOpenWindowsAutomatically)
    }

    @MainActor
    func testGuestRejectsAppStoreEvenWhenLegacyPreferenceSaysAllow() async throws {
        guard #available(iOS 18.4, *) else { throw XCTSkip("Guest profiles require iOS 18.4") }
        let id = UUID()
        let context = try BrowserContext.guest(id: id)
        defer { context.defaults.removePersistentDomain(forName: BrowserContext.preferencesDomain(for: id)) }
        let model = BrowserModel(context: context)
        defer { model.shutdown() }
        model.currentSettings.blockAppLinks = false
        let probe = KioskPolicyProbe(model: model)
        model.webView.navigationDelegate = probe
        let blocked = expectation(description: "Mandatory kiosk redirect protection")
        probe.onDecision = { policy in
            XCTAssertEqual(policy, .cancel)
            blocked.fulfill()
        }
        model.webView.load(URLRequest(url: URL(string: "https://apps.apple.com/us/app/id123")!))
        await fulfillment(of: [blocked], timeout: 10)
        XCTAssertEqual(model.blockedAppLinks, 1)
    }

    func testGuestAllowsWebpagesButRejectsAttachmentsAndNativePreviews() throws {
        let url = URL(string: "https://stayweb-fixture.invalid/")!
        func response(_ type: String, disposition: String? = nil) throws -> HTTPURLResponse {
            var headers = ["Content-Type": type]
            headers["Content-Disposition"] = disposition
            return try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 200,
                                                httpVersion: "HTTP/1.1", headerFields: headers))
        }
        XCTAssertTrue(BrowserPolicy.permitsGuestResponse(try response("text/html; charset=utf-8"),
                                                        isMainFrame: true, canDisplay: true))
        XCTAssertFalse(BrowserPolicy.permitsGuestResponse(try response("text/html", disposition: "ATTACHMENT; filename=test.html"),
                                                         isMainFrame: true, canDisplay: true))
        XCTAssertFalse(BrowserPolicy.permitsGuestResponse(try response("application/pdf"),
                                                         isMainFrame: true, canDisplay: true))
        XCTAssertFalse(BrowserPolicy.permitsGuestResponse(try response("application/octet-stream"),
                                                         isMainFrame: false, canDisplay: false))
        XCTAssertFalse(BrowserPolicy.permitsGuestResponse(try response("application/pdf"),
                                                         isMainFrame: false, canDisplay: true))
        XCTAssertTrue(BrowserPolicy.permitsGuestResponse(try response("text/html"),
                                                        isMainFrame: false, canDisplay: true))
    }

    @MainActor
    func testClosingPreparationSourceRetriesForThePromotedTab() async {
        let started = expectation(description: "Initial source started preparing")
        var releaseInitial: CheckedContinuation<Void, Never>?
        var attempts = 0
        let tabs = TabStore(context: .owner) { model in
            attempts += 1
            if attempts == 1 {
                await withCheckedContinuation { continuation in
                    releaseInitial = continuation
                    started.fulfill()
                }
            }
            await model.start()
        }
        let first = tabs.selected
        let second = tabs.add()
        let waiting = Task { await tabs.prepare(second.browser) }
        await fulfillment(of: [started], timeout: 5)
        tabs.close(first.id)
        releaseInitial?.resume()
        await waiting.value
        XCTAssertTrue(first.browser.isRetired)
        XCTAssertTrue(second.browser.ready, "The promoted source must actually be prepared")
        XCTAssertEqual(attempts, 2)
        tabs.shutdown()
    }

    @MainActor
    func testShutdownCannotReopenAnOldProfileThroughPendingPreparation() async {
        let tabs = TabStore()
        let first = tabs.selected.browser
        _ = tabs.add()
        tabs.shutdown()
        await tabs.prepare(first)
        await first.start()
        _ = tabs.add("https://example.com/")
        XCTAssertTrue(tabs.isRetired)
        XCTAssertEqual(tabs.tabs.count, 2)
        for tab in tabs.tabs {
            XCTAssertTrue(tab.browser.isRetired)
            XCTAssertFalse(tab.browser.ready)
            XCTAssertNil(tab.browser.openNewTab)
            XCTAssertNil(tab.browser.webView.navigationDelegate)
            XCTAssertNil(tab.browser.webView.uiDelegate)
            XCTAssertFalse(tab.browser.webView.isUserInteractionEnabled)
        }
    }

    @MainActor
    func testInvalidProfileCannotFallBackToOwnerStore() {
        guard #available(iOS 18.4, *) else { return }
        let invalid = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
        XCTAssertThrowsError(try BrowserContext.guest(id: invalid))
    }
}

@MainActor
private final class KioskPolicyProbe: NSObject, WKNavigationDelegate {
    let model: BrowserModel
    var onDecision: ((WKNavigationActionPolicy) -> Void)?

    init(model: BrowserModel) { self.model = model }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 preferences: WKWebpagePreferences,
                 decisionHandler: @escaping (WKNavigationActionPolicy, WKWebpagePreferences) -> Void) {
        model.webView(webView, decidePolicyFor: action, preferences: preferences) { policy, preferences in
            decisionHandler(.cancel, preferences)
            let callback = self.onDecision
            self.onDecision = nil
            callback?(policy)
        }
    }
}
