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
    let context: BrowserContext
    private(set) var isRetired = false
    private var primary: BrowserModel
    private var preparation: Task<Void, Never>?
    private var preparationGeneration = UUID()
    private let prepareProtection: @MainActor (BrowserModel) async -> Void

    convenience init(defaults: UserDefaults = .standard) {
        self.init(context: .owner(defaults: defaults))
    }

    init(context: BrowserContext,
         prepareProtection: @escaping @MainActor (BrowserModel) async -> Void = { await $0.start() }) {
        self.context = context
        self.prepareProtection = prepareProtection
        let model = BrowserModel(context: context)
        primary = model
        let tab = BrowserTab(browser: model)
        tabs = [tab]
        selectedID = tab.id
        configure(model)
    }

    var selected: BrowserTab { tabs.first { $0.id == selectedID } ?? tabs[0] }

    func prepare(_ model: BrowserModel) async {
        while !isRetired, !model.isRetired, !Task.isCancelled {
            let source = primary
            let generation = preparationGeneration
            if preparation == nil {
                preparation = Task { await prepareProtection(source) }
            }
            await preparation?.value
            guard !isRetired, !model.isRetired, !Task.isCancelled else { return }
            // A closed source may finish its asynchronous compilation after a
            // replacement was selected. Wait for the replacement's preparation
            // instead of marking this tab ready from stale or unprepared data.
            guard generation == preparationGeneration else { continue }
            if model !== source { model.reuseProtection(from: source) }
            return
        }
    }

    @discardableResult
    func add(_ address: String? = nil) -> BrowserTab {
        guard !isRetired else { return selected }
        selected.browser.webView.pauseAllMediaPlayback(completionHandler: nil)
        let tab = BrowserTab(browser: BrowserModel(context: context))
        configure(tab.browser)
        tabs.append(tab)
        selectedID = tab.id
        if let address {
            Task { [weak self, weak model = tab.browser] in
                guard let self, let model else { return }
                await self.prepare(model)
                guard !self.isRetired, !Task.isCancelled, self.tabs.contains(where: { $0.browser === model }) else { return }
                model.navigate(address)
            }
        }
        return tab
    }

    func select(_ id: UUID) {
        guard !isRetired, tabs.contains(where: { $0.id == id }), selectedID != id else { return }
        selected.browser.webView.pauseAllMediaPlayback(completionHandler: nil)
        selectedID = id
        selected.browser.refreshSettings()
    }

    func close(_ id: UUID) {
        guard !isRetired, let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        let removed = tabs[index].browser
        removed.shutdown()
        if tabs.count == 1 { add() }
        tabs.removeAll { $0.id == id }
        if selectedID == id { selectedID = tabs[min(index, tabs.count - 1)].id }
        if removed === primary {
            preparation?.cancel()
            preparation = nil
            preparationGeneration = UUID()
            primary = selected.browser
        }
    }

    func clearData() async {
        guard !isRetired else { return }
        for tab in tabs {
            tab.browser.webView.stopLoading()
            tab.browser.webView.pauseAllMediaPlayback(completionHandler: nil)
        }
        await selected.browser.clearData()
    }

    func shutdown() {
        guard !isRetired else { return }
        isRetired = true
        preparation?.cancel()
        preparation = nil
        for tab in tabs { tab.browser.shutdown() }
    }

    private func configure(_ model: BrowserModel) {
        model.openNewTab = { [weak self] url in self?.add(url.absoluteString) }
    }
}
