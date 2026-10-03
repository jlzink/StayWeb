import Foundation

struct SiteSettings: Codable, Equatable {
    var blockAds = true
    var desktop = true
    var blockAppLinks = true
    var disneyCompatibility = true

    init() {}
    private enum CodingKeys: String, CodingKey {
        case blockAds, desktop, blockAppLinks, disneyCompatibility
    }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        blockAds = try values.decodeIfPresent(Bool.self, forKey: .blockAds) ?? true
        desktop = try values.decodeIfPresent(Bool.self, forKey: .desktop) ?? true
        blockAppLinks = try values.decodeIfPresent(Bool.self, forKey: .blockAppLinks) ?? true
        disneyCompatibility = try values.decodeIfPresent(Bool.self, forKey: .disneyCompatibility) ?? true
    }
}

enum BrowserPolicy {
    static func matches(_ host: String, domain: String) -> Bool {
        let normalized = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return normalized == domain || normalized.hasSuffix("." + domain)
    }

    static func isAppStore(_ url: URL) -> Bool {
        guard let host = url.host else { return false }
        return matches(host, domain: "apps.apple.com") || matches(host, domain: "itunes.apple.com")
    }

    static func isWeb(_ url: URL) -> Bool {
        ["https", "http"].contains(url.scheme?.lowercased() ?? "")
    }

    static func address(_ text: String) -> URL? {
        let input = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return nil }
        if let url = URL(string: input), isWeb(url), url.host != nil { return url }
        if !input.contains(where: { $0.isWhitespace }), input.contains("."), !input.contains("://"),
           let url = URL(string: "https://" + input), url.host != nil { return url }
        var search = URLComponents(string: "https://duckduckgo.com/")!
        search.queryItems = [URLQueryItem(name: "q", value: input)]
        return search.url
    }
}

/// One automatic recovery per user navigation. A repeating gate remains visible.
struct DisneyGateRecovery {
    private(set) var attempted = false
    mutating func reset() { attempted = false }
    mutating func destination(for url: URL) -> URL? {
        guard !attempted, let destination = BrowserPolicy.disneyWebHome(for: url) else { return nil }
        attempted = true
        return destination
    }
}

extension BrowserPolicy {
    // Compatibility identity only: actual WebKit/media capabilities do not change.
    static let desktopSafariAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.5 Safari/605.1.15"

    static func isDisney(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", let host = url.host?.lowercased() else { return false }
        return host == "www.disneyplus.com" || host == "disneyplus.com"
    }

    static func disneyWebHome(for url: URL) -> URL? {
        guard isDisney(url) else { return nil }
        let pieces = url.path.split(separator: "/").map(String.init)
        guard pieces.last == "get-app", pieces.count <= 2 else { return nil }
        if pieces.count == 2 {
            guard pieces[0].range(of: "^[a-z]{2}(-[a-z]{2})?$", options: [.regularExpression, .caseInsensitive]) != nil else { return nil }
        }
        var result = URLComponents()
        result.scheme = "https"
        result.host = url.host
        result.path = "/" + (Array(pieces.dropLast()) + ["home"]).joined(separator: "/")
        return result.url
    }
}
