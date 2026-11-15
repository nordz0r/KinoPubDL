import Foundation

enum CookieBrowser: String, CaseIterable, Identifiable {
    case safari, chrome, firefox, edge, brave, chromium, opera, vivaldi
    var id: String { rawValue }
    var title: String {
        switch self {
        case .safari: return "Safari"
        case .chrome: return "Google Chrome"
        case .firefox: return "Firefox"
        case .edge: return "Microsoft Edge"
        case .brave: return "Brave"
        case .chromium: return "Chromium"
        case .opera: return "Opera"
        case .vivaldi: return "Vivaldi"
        }
    }
    var arguments: [String] { ["--cookies-from-browser", rawValue] }
}

enum KinoPubAddress {
    static func validate(_ text: String) throws -> String {
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased(),
              ["https", "http"].contains(scheme),
              ["kino.watch", "www.kino.watch", "kino.pub", "www.kino.pub"].contains(url.host?.lowercased() ?? ""),
              url.user == nil, url.password == nil,
              url.path.range(of: #"^/item/view/[0-9]+(?:/s[0-9]+e[0-9]+)?/?$"#, options: .regularExpression) != nil else {
            throw MediaError.invalidURL
        }
        return url.absoluteString
    }
}
