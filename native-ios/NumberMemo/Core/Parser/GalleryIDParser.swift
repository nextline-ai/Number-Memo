import Foundation

public enum MangaUrls {
    public static var configuredHome: String {
        let saved = UserDefaults.standard.string(forKey: "manga.site_address")
        if let saved, !saved.isEmpty {
            let clean = saved.trimmingCharacters(in: .whitespacesAndNewlines)
            if clean.contains("://") {
                return clean.hasSuffix("/") ? clean : clean + "/"
            } else {
                return "https://\(clean)/"
            }
        }
        return "https://manga.la/"
    }

    public static var home: String {
        configuredHome
    }

    public static var configuredHost: String {
        URL(string: home)?.host?.lowercased() ?? "manga.la"
    }

    public static func galleryUrl(for galleryId: Int64) -> String {
        "\(home)galleries/\(galleryId).html"
    }

    public static func artistAllUrl(for artist: String) -> String {
        let trimmed = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? trimmed
        return "\(home)artist/\(encoded)-all.html"
    }

    public static func isTranslatedUrl(_ urlString: String) -> Bool {
        guard let host = URL(string: urlString)?.host?.lowercased() else { return false }
        return host.contains("translate.google") || host.contains("translate.goog")
    }

    public static func originalMangaUrl(_ urlString: String) -> String? {
        guard let url = URL(string: urlString) else { return nil }
        if let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
           let nested = components.queryItems?.first(where: { $0.name == "u" })?.value,
           nested.contains("manga") || nested.contains("galleries") || nested.contains("reader") {
            return nested
        }
        let host = url.host?.lowercased() ?? ""
        let currentHost = configuredHost
        if host.contains("-la.translate.goog") || host.contains("manga-la.translate.goog") || host.hasSuffix(".translate.goog") {
            var comp = URLComponents()
            comp.scheme = "https"
            comp.host = currentHost
            comp.path = url.path
            return comp.string
        }
        if host.hasSuffix(currentHost) || host.hasSuffix("manga.la") {
            return urlString
        }
        return nil
    }

    public static func translatedMangaUrl(_ urlString: String) -> String {
        let original = originalMangaUrl(urlString) ?? urlString
        guard let url = URL(string: original), let host = url.host, !host.isEmpty else {
            return original
        }
        let path = url.path.isEmpty ? "/" : url.path
        var comp = URLComponents()
        comp.scheme = "https"
        comp.host = host.replacingOccurrences(of: ".", with: "-") + ".translate.goog"
        comp.path = path
        comp.queryItems = [
            URLQueryItem(name: "_x_tr_sl", value: "auto"),
            URLQueryItem(name: "_x_tr_tl", value: "ko"),
            URLQueryItem(name: "_x_tr_hl", value: "ko"),
        ]
        return comp.string ?? original
    }
}

public enum GalleryIDParser {
    private static let mangaIdRegex: NSRegularExpression = {
        let pattern = #"(?:(?:[a-zA-Z0-9-]+\.)+[a-zA-Z]{2,}/)?(?:galleries|reader)/(\d{4,10})(?:\.html)?|(?:(?:[a-zA-Z0-9-]+\.)+[a-zA-Z]{2,}/)?[^/\s]+/[^/\s]*-(\d{4,10})\.html"#
        return try! NSRegularExpression(pattern: pattern, options: .caseInsensitive)
    }()

    private static let nestedUrlRegex: NSRegularExpression = {
        let pattern = #"[?&]u=([^&\s]+)"#
        return try! NSRegularExpression(pattern: pattern, options: .caseInsensitive)
    }()

    private static let tokenDigitsRegex: NSRegularExpression = {
        let pattern = #"^\d{4,10}$"#
        return try! NSRegularExpression(pattern: pattern, options: [])
    }()

    /// Extracts gallery IDs from text, URLs, or share payloads.
    public static func parse(_ raw: String) -> [Int64] {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return [] }

        var ids: [Int64] = []
        var seen = Set<Int64>()

        func add(_ digits: String) {
            guard let id = Int64(digits), id >= 1000, id <= 9_999_999_999 else { return }
            if seen.insert(id).inserted {
                ids.append(id)
            }
        }

        func addFrom(_ value: String, depth: Int = 0) {
            guard depth <= 3 else { return }
            let nsValue = value as NSString
            let matches = mangaIdRegex.matches(in: value, range: NSRange(location: 0, length: nsValue.length))
            for match in matches {
                if match.numberOfRanges > 1 && match.range(at: 1).location != NSNotFound {
                    add(nsValue.substring(with: match.range(at: 1)))
                } else if match.numberOfRanges > 2 && match.range(at: 2).location != NSNotFound {
                    add(nsValue.substring(with: match.range(at: 2)))
                }
            }

            let nestedMatches = nestedUrlRegex.matches(in: value, range: NSRange(location: 0, length: nsValue.length))
            for match in nestedMatches {
                if match.numberOfRanges > 1 && match.range(at: 1).location != NSNotFound {
                    let encoded = nsValue.substring(with: match.range(at: 1))
                    if let decoded = encoded.removingPercentEncoding, (decoded.localizedCaseInsensitiveContains("manga") || decoded.contains("galleries") || decoded.contains("reader")) {
                        addFrom(decoded, depth: depth + 1)
                    }
                }
            }
        }

        addFrom(text)
        if !ids.isEmpty {
            return ids
        }

        // Fallback: split by whitespace, comma, semicolons
        let tokens = text.components(separatedBy: CharacterSet(charactersIn: " \t\r\n,;"))
        for token in tokens {
            let nsToken = token as NSString
            let matches = tokenDigitsRegex.matches(in: token, range: NSRange(location: 0, length: nsToken.length))
            if !matches.isEmpty {
                add(token)
            }
        }

        return ids
    }
}
