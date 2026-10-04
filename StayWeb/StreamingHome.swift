import SwiftUI

struct StreamingShortcut: Identifiable, Codable {
    var id = UUID()
    var name: String
    var address: String
    var symbol: String = "play.tv.fill"
    var hue: Double = 0.5

    static let builtins: [StreamingShortcut] = [
        .init(name: "Disney+", address: "https://www.disneyplus.com/", hue: 0.56),
        .init(name: "Hulu", address: "https://www.hulu.com/", hue: 0.40),
        .init(name: "Peacock", address: "https://www.peacocktv.com/", hue: 0.12),
        .init(name: "Prime Video", address: "https://www.primevideo.com/", hue: 0.57),
        .init(name: "Netflix", address: "https://www.netflix.com/", hue: 0.0),
        .init(name: "HBO Max", address: "https://www.hbomax.com/", hue: 0.67),
        .init(name: "Paramount+", address: "https://www.paramountplus.com/", hue: 0.62),
        .init(name: "Apple TV", address: "https://tv.apple.com/", hue: 0.72),
        .init(name: "YouTube", address: "https://www.youtube.com/", symbol: "play.rectangle.fill", hue: 0.0),
        .init(name: "YouTube TV", address: "https://tv.youtube.com/", hue: 0.02),
        .init(name: "Tubi", address: "https://tubitv.com/", hue: 0.14),
        .init(name: "Pluto TV", address: "https://pluto.tv/", hue: 0.80),
        .init(name: "Plex", address: "https://app.plex.tv/", hue: 0.10),
        .init(name: "The Roku Channel", address: "https://therokuchannel.roku.com/", hue: 0.77),
        .init(name: "Crunchyroll", address: "https://www.crunchyroll.com/", hue: 0.07),
        .init(name: "Discovery+", address: "https://www.discoveryplus.com/", hue: 0.58),
        .init(name: "ESPN", address: "https://www.espn.com/watch/", symbol: "sportscourt.fill", hue: 0.0),
        .init(name: "Fubo", address: "https://www.fubo.tv/", hue: 0.06),
        .init(name: "Sling TV", address: "https://www.sling.com/", hue: 0.57),
        .init(name: "Philo", address: "https://www.philo.com/", hue: 0.56),
        .init(name: "STARZ", address: "https://www.starz.com/", hue: 0.10),
        .init(name: "AMC+", address: "https://www.amcplus.com/", hue: 0.46),
        .init(name: "Shudder", address: "https://www.shudder.com/", hue: 0.0),
        .init(name: "BritBox", address: "https://www.britbox.com/", hue: 0.61),
        .init(name: "Acorn TV", address: "https://acorn.tv/", hue: 0.02),
        .init(name: "PBS", address: "https://www.pbs.org/", hue: 0.62),
        .init(name: "Twitch", address: "https://www.twitch.tv/", hue: 0.75),
        .init(name: "Dailymotion", address: "https://www.dailymotion.com/", hue: 0.59)
    ]

    static func custom(name: String, address: String) -> StreamingShortcut? {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !text.isEmpty, !text.contains(where: { $0.isWhitespace }),
              let url = URL(string: text.contains("://") ? text : "https://" + text),
              BrowserPolicy.isWeb(url), let host = url.host, host.contains("."),
              url.user == nil, url.password == nil else { return nil }
        return .init(name: name, address: url.absoluteString)
    }
}

struct StreamingHome: View {
    let ready: Bool
    let open: (String) -> Void
    let openInNewTab: (String) -> Void
    @AppStorage("streamingShortcuts") private var saved = Data()
    @State private var query = ""
    @State private var adding = false
    @State private var name = ""
    @State private var address = ""
    private var custom: [StreamingShortcut] {
        (try? JSONDecoder().decode([StreamingShortcut].self, from: saved)) ?? []
    }
    private var shortcuts: [StreamingShortcut] {
        (custom + StreamingShortcut.builtins).filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(spacing: 16) {
                    Image("StayWebMark").resizable().scaledToFit().frame(width: 72, height: 72)
                        .clipShape(RoundedRectangle(cornerRadius: 18))
                    VStack(alignment: .leading, spacing: 5) {
                        Text("StayWeb").font(.largeTitle.bold())
                        Text("Your streaming. Your browser.").font(.subheadline).foregroundStyle(.secondary)
                    }
                }.padding(.top, 12)
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Find a streaming service", text: $query).autocorrectionDisabled()
                    if !query.isEmpty { Button { query = "" } label: { Image(systemName: "xmark.circle.fill") } }
                }.padding(12).background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
                HStack {
                    Text("STREAMING SERVICES").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Spacer()
                    Button { name = ""; address = ""; adding = true } label: { Label("Add", systemImage: "plus") }
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 145), spacing: 12)], spacing: 12) {
                    ForEach(shortcuts) { item in
                        Button { open(item.address) } label: {
                            VStack(alignment: .leading, spacing: 20) {
                                HStack {
                                    Image(systemName: item.symbol).font(.title2)
                                        .foregroundStyle(Color(hue: item.hue, saturation: 0.65, brightness: 0.95))
                                    Spacer()
                                    Image(systemName: "arrow.up.right").font(.caption).foregroundStyle(.white.opacity(0.55))
                                }
                                Text(item.name).font(.headline).foregroundStyle(.white).multilineTextAlignment(.leading)
                            }.padding(18).frame(maxWidth: .infinity, minHeight: 116, alignment: .leading)
                                .background(LinearGradient(colors: [Color(hue: item.hue, saturation: 0.65, brightness: 0.30), Color(red: 0.035, green: 0.06, blue: 0.13)], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 18))
                        }.buttonStyle(.plain).disabled(!ready)
                            .contextMenu {
                                Button { openInNewTab(item.address) } label: { Label("Open in New Tab", systemImage: "plus.square.on.square") }
                                if custom.contains(where: { $0.id == item.id }) {
                                    Button("Remove Shortcut", role: .destructive) {
                                        saved = (try? JSONEncoder().encode(custom.filter { $0.id != item.id })) ?? Data()
                                    }
                                }
                            }
                    }
                }
                if shortcuts.isEmpty { Text("No matching services. Add your own shortcut above.").foregroundStyle(.secondary) }
                Text("Touch and hold a service to open it in a new tab.").font(.footnote).foregroundStyle(.secondary)
                if !ready { ProgressView("Preparing protection…") }
            }.padding(20).frame(maxWidth: 1000)
                .frame(maxWidth: .infinity)
        }.background(Color(uiColor: .systemBackground))
        .sheet(isPresented: $adding) {
            NavigationStack {
                Form {
                    TextField("Service name", text: $name)
                    TextField("Website address", text: $address).keyboardType(.URL)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                }.navigationTitle("Add Streaming Service")
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button("Cancel") { adding = false } }
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Add") {
                                if let item = StreamingShortcut.custom(name: name, address: address) {
                                    saved = (try? JSONEncoder().encode(custom + [item])) ?? Data()
                                    adding = false
                                }
                            }.disabled(StreamingShortcut.custom(name: name, address: address) == nil)
                        }
                    }
            }
        }
    }
}
