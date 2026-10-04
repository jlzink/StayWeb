import SwiftUI
import WebKit

struct BrowserTab: Identifiable {
    let id = UUID()
    let browser: BrowserModel
}

@MainActor
final class TabStore: ObservableObject {
    @Published private(set) var tabs: [BrowserTab]
    @Published private(set) var selectedID: UUID
    private let defaults: UserDefaults
    private let primary: BrowserModel
    private var preparation: Task<Void, Never>?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let model = BrowserModel(defaults: defaults)
        primary = model
        let tab = BrowserTab(browser: model)
        tabs = [tab]
        selectedID = tab.id
        configure(model)
    }

    var selected: BrowserTab { tabs.first { $0.id == selectedID } ?? tabs[0] }

    func prepare(_ model: BrowserModel) async {
        if preparation == nil { preparation = Task { await primary.start() } }
        await preparation?.value
        if model !== primary { model.reuseProtection(from: primary) }
    }

    @discardableResult
    func add(_ address: String? = nil) -> BrowserTab {
        selected.browser.webView.pauseAllMediaPlayback(completionHandler: nil)
        let tab = BrowserTab(browser: BrowserModel(defaults: defaults))
        configure(tab.browser)
        tabs.append(tab)
        selectedID = tab.id
        if let address {
            Task { [weak self, weak model = tab.browser] in
                guard let self, let model else { return }
                await self.prepare(model)
                guard self.tabs.contains(where: { $0.browser === model }) else { return }
                model.navigate(address)
            }
        }
        return tab
    }

    func select(_ id: UUID) {
        guard tabs.contains(where: { $0.id == id }), selectedID != id else { return }
        selected.browser.webView.pauseAllMediaPlayback(completionHandler: nil)
        selectedID = id
        selected.browser.refreshSettings()
    }

    func close(_ id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        let removed = tabs[index].browser
        removed.webView.stopLoading()
        removed.webView.pauseAllMediaPlayback(completionHandler: nil)
        removed.openNewTab = nil
        if tabs.count == 1 { add() }
        tabs.removeAll { $0.id == id }
        if selectedID == id { selectedID = tabs[min(index, tabs.count - 1)].id }
    }

    func clearData() async {
        for tab in tabs {
            tab.browser.webView.stopLoading()
            tab.browser.webView.pauseAllMediaPlayback(completionHandler: nil)
        }
        await selected.browser.clearData()
    }

    private func configure(_ model: BrowserModel) {
        model.openNewTab = { [weak self] url in self?.add(url.absoluteString) }
    }
}
