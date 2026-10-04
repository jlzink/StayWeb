import SwiftUI

struct TabSwitcher: View {
    @ObservedObject var tabs: TabStore
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                ForEach(tabs.tabs) { tab in
                    TabRow(browser: tab.browser, selected: tabs.selectedID == tab.id,
                           select: { dismiss(); tabs.select(tab.id) },
                           close: { tabs.close(tab.id) })
                }
            }.navigationTitle("Tabs (\(tabs.tabs.count))")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button { dismiss(); tabs.add() } label: { Label("New Tab", systemImage: "plus") }
                    }
                    ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                }
        }
    }
}

private struct TabRow: View {
    @ObservedObject var browser: BrowserModel
    let selected: Bool
    let select: () -> Void
    let close: () -> Void
    var body: some View {
        HStack(spacing: 14) {
            Button(action: select) {
                HStack(spacing: 14) {
                    Image(systemName: browser.address.isEmpty ? "house.fill" : "globe")
                        .font(.title2).foregroundStyle(.teal)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(browser.address.isEmpty ? "Streaming Home" : browser.title).font(.headline).lineLimit(2)
                        Text(browser.address.isEmpty ? "Choose a streaming service" : browser.currentHost)
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    if selected { Image(systemName: "checkmark.circle.fill").foregroundStyle(.teal) }
                }.contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel("Switch to \(browser.title)")
            Button(action: close) { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary).padding(8) }
                .buttonStyle(.plain).accessibilityLabel("Close \(browser.title)")
        }.padding(.vertical, 8)
    }
}
