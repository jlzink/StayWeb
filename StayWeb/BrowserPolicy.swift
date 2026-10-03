import Foundation

struct SiteSettings: Codable, Equatable {
    var blockAds = true
    var desktop = true
    var blockAppLinks = true
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
