import Foundation

public struct HitomiGalleryInfo: Sendable {
    public let hash: String?
    public let title: String?
    public let artists: String?
    public let language: String?
    public let type: String?
    public let published: String?
    public let tags: String?
}

public enum HitomiAPIClient {
    private static let userAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_4 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Mobile/15E148 Safari/604.1"

    public static func fetchGalleryInfo(galleryId: Int64) async throws -> HitomiGalleryInfo {
        let urls = [
            "https://ltn.gold-usergeneratedcontent.net/galleries/\(galleryId).js",
            "https://ltn.hitomi.la/galleries/\(galleryId).js"
        ]

        var lastError: Error?
        var saw404 = false

        for urlString in urls {
            guard let url = URL(string: urlString) else { continue }
            var request = URLRequest(url: url)
            request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            request.setValue("https://hitomi.la/galleries/\(galleryId).html", forHTTPHeaderField: "Referer")
            request.timeoutInterval = 15

            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse else { continue }
                if http.statusCode == 404 {
                    saw404 = true
                    continue
                }
                guard http.statusCode == 200, let body = String(data: data, encoding: .utf8) else {
                    continue
                }
                return try parseGalleryJS(body)
            } catch {
                lastError = error
            }
        }

        if saw404 {
            throw URLError(.fileDoesNotExist)
        }
        throw lastError ?? URLError(.cannotConnectToHost)
    }

    public static func fetchGalleryFiles(galleryId: Int64) async throws -> [String] {
        let urls = [
            "https://ltn.gold-usergeneratedcontent.net/galleries/\(galleryId).js",
            "https://ltn.hitomi.la/galleries/\(galleryId).js"
        ]

        var lastError: Error?

        for urlString in urls {
            guard let url = URL(string: urlString) else { continue }
            var request = URLRequest(url: url)
            request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            request.setValue("https://hitomi.la/galleries/\(galleryId).html", forHTTPHeaderField: "Referer")
            request.timeoutInterval = 15

            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                      let body = String(data: data, encoding: .utf8) else {
                    continue
                }
                return try parseGalleryHashes(body)
            } catch {
                lastError = error
            }
        }

        throw lastError ?? URLError(.cannotConnectToHost)
    }

    private static func parseGalleryHashes(_ body: String) throws -> [String] {
        var jsonText = body.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = "var galleryinfo ="
        if jsonText.hasPrefix(prefix) {
            jsonText = String(jsonText.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        } else if let idx = jsonText.firstIndex(of: "{") {
            jsonText = String(jsonText[idx...])
        }
        if jsonText.hasSuffix(";") {
            jsonText = String(jsonText.dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        guard let data = jsonText.data(using: .utf8),
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let files = json["files"] as? [[String: Any]] else {
            throw URLError(.cannotParseResponse)
        }

        return files.compactMap { $0["hash"] as? String }
    }

    private static func parseGalleryJS(_ body: String) throws -> HitomiGalleryInfo {
        var jsonText = body.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = "var galleryinfo ="
        if jsonText.hasPrefix(prefix) {
            jsonText = String(jsonText.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        } else if let idx = jsonText.firstIndex(of: "{") {
            jsonText = String(jsonText[idx...])
        }
        if jsonText.hasSuffix(";") {
            jsonText = String(jsonText.dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        guard let data = jsonText.data(using: .utf8),
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw URLError(.cannotParseResponse)
        }

        var hash: String?
        if let files = json["files"] as? [[String: Any]], let first = files.first, let h = first["hash"] as? String {
            hash = h
        }

        var artistsList: [String] = []
        if let rawArtists = json["artists"] as? [[String: Any]] {
            for item in rawArtists {
                if let name = item["artist"] as? String {
                    artistsList.append(name)
                }
            }
        }

        var tagsList: [String] = []
        if let rawTags = json["tags"] as? [[String: Any]] {
            for item in rawTags {
                if let tag = item["tag"] as? String {
                    tagsList.append(tag)
                }
            }
        }

        let rawTitle = (json["japanese_title"] as? String) ?? (json["title"] as? String)
        let unescapedTitle = rawTitle?
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&quot;", with: "\"")

        let dateStr = (json["date"] as? String)?.components(separatedBy: " ").first

        return HitomiGalleryInfo(
            hash: hash,
            title: unescapedTitle,
            artists: artistsList.isEmpty ? nil : artistsList.joined(separator: ", "),
            language: json["language"] as? String,
            type: json["type"] as? String,
            published: dateStr,
            tags: tagsList.isEmpty ? nil : tagsList.joined(separator: ", ")
        )
    }

    public static func downloadCover(galleryId: Int64, hash: String, destinationDir: URL) async throws -> URL {
        guard hash.count >= 3 else { throw URLError(.badURL) }
        let a = String(hash.suffix(1))
        let bStart = hash.index(hash.endIndex, offsetBy: -3)
        let bEnd = hash.index(hash.endIndex, offsetBy: -1)
        let b = String(hash[bStart..<bEnd])

        let candidates = [
            ("https://tn.gold-usergeneratedcontent.net/webpsmalltn/\(a)/\(b)/\(hash).webp", "webp"),
            ("https://atn.gold-usergeneratedcontent.net/webpsmalltn/\(a)/\(b)/\(hash).webp", "webp"),
            ("https://btn.gold-usergeneratedcontent.net/webpsmalltn/\(a)/\(b)/\(hash).webp", "webp"),
            ("https://tn.gold-usergeneratedcontent.net/webpbigtn/\(a)/\(b)/\(hash).webp", "webp"),
            ("https://tn.gold-usergeneratedcontent.net/avifsmalltn/\(a)/\(b)/\(hash).avif", "avif")
        ]

        var lastError: Error?

        for (candidateUrl, ext) in candidates {
            guard let url = URL(string: candidateUrl) else { continue }
            var request = URLRequest(url: url)
            request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            request.setValue("https://hitomi.la/galleries/\(galleryId).html", forHTTPHeaderField: "Referer")
            request.setValue("image/webp,image/avif,image/*,*/*;q=0.8", forHTTPHeaderField: "Accept")
            request.timeoutInterval = 15

            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200, data.count > 32 else {
                    continue
                }
                let dest = destinationDir.appendingPathComponent("\(galleryId).\(ext)")
                try data.write(to: dest, options: .atomic)
                return dest
            } catch {
                lastError = error
            }
        }

        throw lastError ?? URLError(.cannotDecodeContentData)
    }
}
