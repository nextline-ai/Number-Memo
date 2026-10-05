import Foundation

/// Gelbooru 0.1.11 / booru.org exposes HTML pages rather than the modern DAPI.
enum BooruLegacyHTML {
    private static func url(_ value: String?, server: BooruServer) -> URL? {
        guard let value, var parts = URLComponents(string: value) else { return nil }
        // Old templates still emit HTTP media links. Request their HTTPS equivalent.
        if parts.scheme == "http" { parts.scheme = "https" }
        return BooruDecoder.safeURL(parts.string, base: server.baseURL)
    }

    static func posts(_ data: Data, server: BooruServer) throws -> [BooruPost] {
        let html = try BooruHTML.html(data)
        var seen = Set<Int64>()
        let posts = BooruHTML.matches("<a\\b([^>]*)>((?:(?!</a>).)*<img\\b[^>]*>(?:(?!</a>).)*)</a>", html).compactMap { match -> BooruPost? in
            let anchor = BooruHTML.attributes(match[1])
            guard let imageMatch = BooruHTML.matches("<img\\b([^>]*)>", match[2]).first else { return nil }
            let image = BooruHTML.attributes(imageMatch[1])
            let link = anchor["href"].flatMap { URLComponents(string: $0) }
            let linkedID = link?.queryItems?.contains(where: { $0.name == "s" && $0.value == "view" }) == true
                ? link?.queryItems?.first { $0.name == "id" }?.value.flatMap(Int64.init) : nil
            let elementID = anchor["id"].flatMap { $0.hasPrefix("p") ? Int64($0.dropFirst()) : nil }
            guard let id = elementID ?? linkedID, seen.insert(id).inserted,
                  let preview = url(image["data-original"] ?? image["data-src"] ?? image["src"], server: server) else { return nil }
            let title = image["title"] ?? image["alt"] ?? ""
            let terms = title.split(whereSeparator: \.isWhitespace).map(String.init)
            let metadata = BooruHTML.matches("posts\\[" + String(id) + "\\]\\s*=\\s*\\{(.*?)\\}", html).first?[1] ?? ""
            let score = terms.first { $0.hasPrefix("score:") }.flatMap { Int($0.dropFirst(6)) }
                ?? BooruHTML.matches("[\"']?score[\"']?\\s*:\\s*[\"']?(-?\\d+)", metadata).first.flatMap { Int($0[1]) } ?? 0
            let rating = terms.first { $0.hasPrefix("rating:") }.map { String($0.dropFirst(7)) }
                ?? BooruHTML.matches("[\"']?rating[\"']?\\s*:\\s*[\"']([^\"']+)", metadata).first?[1] ?? ""
            return BooruPost(serverID: server.id, postID: id, previewURL: preview,
                             width: 0, height: 0, tags: terms.filter { !$0.hasPrefix("score:") && !$0.hasPrefix("rating:") },
                             artists: [], rating: normalizedRating(rating, server: server), score: score, fileExtension: "")
        }
        let lower = html.lowercased()
        guard !posts.isEmpty || ["nobody here", "no images", "no posts", "no results"].contains(where: lower.contains) else { throw BooruError.invalidResponse }
        return posts
    }

    static func post(_ data: Data, server: BooruServer, id: Int64, preview: URL? = nil) throws -> BooruPost {
        let html = try BooruHTML.html(data)
        let images = BooruHTML.matches("<(?:img|video|source)\\b([^>]*)>", html).map { BooruHTML.attributes($0[1]) }
        let image = images.first { $0["id"] == "image" || $0["alt"] == "img" || $0["onclick"]?.contains("Note.toggle") == true }
            ?? images.first { $0["type"]?.hasPrefix("video/") == true }
        let original = BooruHTML.matches("<a\\b([^>]*)>(.*?)</a>", html).compactMap { match -> URL? in
            guard ["original image", "original", "original video"].contains(BooruHTML.plainText(match[2]).lowercased()),
                  let candidate = url(BooruHTML.attributes(match[1])["href"], server: server),
                  ["jpg", "jpeg", "png", "gif", "webp", "avif", "jxl", "mp4", "webm", "mov"].contains(candidate.pathExtension.lowercased()) else { return nil }
            // The sidebar may contain a tag named "original" before the download link.
            return candidate
        }.first
        // Some Gelbooru video pages expose the playable MP4 only in a nested
        // source element; the video itself has no src (and may have a poster).
        let videoSources = images.filter { ($0["type"] ?? "").hasPrefix("video/") }
        let playableVideo = videoSources.first { $0["type"] == "video/mp4" }
            ?? videoSources.first
        let videoURL = url(playableVideo?["src"] ?? playableVideo?["data-src"], server: server)
        let imageURL = url(image?["data-original"] ?? image?["data-src"] ?? image?["src"], server: server)
        guard let file = videoURL ?? original ?? imageURL else { throw BooruError.invalidResponse }
        let rawTags = BooruHTML.matches("<textarea\\b([^>]*)>(.*?)</textarea>", html).first { BooruHTML.attributes($0[1])["name"] == "tags" }.map { BooruHTML.plainText($0[2]) } ?? ""
        let dimensions = BooruHTML.matches("Size:\\s*(\\d+)\\s*x\\s*(\\d+)", html).first
        let rating = BooruHTML.matches("Rating:\\s*([a-z]+)", html).first?[1] ?? ""
        let score = BooruHTML.matches("Score:\\s*(?:<[^>]*>\\s*)?(-?\\d+)", html).first.flatMap { Int($0[1]) } ?? 0
        let sidebar = try tags(data)
        let tagNames = rawTags.isEmpty ? sidebar.map(\.name) : rawTags.split(whereSeparator: \.isWhitespace).map(String.init)
        return BooruPost(serverID: server.id, postID: id, previewURL: preview, fileURL: file,
                         width: Int(dimensions?[1] ?? image?["width"] ?? "") ?? 0,
                         height: Int(dimensions?[2] ?? image?["height"] ?? "") ?? 0,
                         tags: tagNames, artists: sidebar.filter(\.isArtist).map(\.name),
                         rating: normalizedRating(rating, server: server), score: score, fileExtension: file.pathExtension)
    }

    private static func normalizedRating(_ raw: String, server: BooruServer) -> String {
        let rating = raw.lowercased()
        if rating == "safe" || rating == "s" && !server.usesModernRatings { return "g" }
        return String(rating.prefix(1))
    }

    static func tags(_ data: Data) throws -> [BooruTag] {
        let html = try BooruHTML.html(data)
        var seen = Set<String>()
        return BooruHTML.matches("<li\\b([^>]*)>(.*?)</li>", html).compactMap { item in
            for match in BooruHTML.matches("<a\\b([^>]*)>(.*?)</a>", item[2]) {
                let attrs = BooruHTML.attributes(match[1])
                guard let href = attrs["href"], let parts = URLComponents(string: href),
                      let name = parts.queryItems?.first(where: { $0.name == "tags" })?.value,
                      !["+", "-", "?"].contains(BooruHTML.plainText(match[2])),
                      !name.contains(" "), !name.isEmpty, seen.insert(name).inserted else { continue }
                let count = BooruHTML.matches("(?:</a>\\s*|<small[^>]*>)([0-9]+)", item[2]).last.flatMap { Int($0[1]) } ?? 0
                return BooruTag(name: name, count: count, category: item[1].contains("artist") ? 1 : 0)
            }
            return nil
        }
    }

    static func nextOffset(_ data: Data, after offset: Int) throws -> Int? {
        try BooruHTML.matches("<a\\b([^>]*)>", BooruHTML.html(data)).compactMap { match -> Int? in
            guard let href = BooruHTML.attributes(match[1])["href"], let parts = URLComponents(string: href),
                  parts.queryItems?.contains(where: { $0.name == "s" && $0.value == "list" }) == true,
                  let raw = parts.queryItems?.first(where: { $0.name == "pid" })?.value,
                  let next = Int(raw), next > offset else { return nil }
            return next
        }.min()
    }

    static func nextPageURL(_ data: Data, server: BooruServer, after offset: Int) throws -> URL? {
        try BooruHTML.matches("<a\\b([^>]*)>", BooruHTML.html(data)).compactMap { match -> (Int, URL)? in
            guard let href = BooruHTML.attributes(match[1])["href"],
                  let resolved = URL(string: href, relativeTo: server.baseURL.appendingPathComponent("index.php"))?.absoluteURL,
                  var parts = URLComponents(url: resolved, resolvingAgainstBaseURL: false) else { return nil }
            if parts.scheme == "http" { parts.scheme = "https" }
            guard let next = parts.url,
                  BooruWebTransport.sameOrigin(next, server.baseURL),
                  parts.queryItems?.contains(where: { $0.name == "s" && $0.value == "list" }) == true,
                  let raw = parts.queryItems?.first(where: { $0.name == "pid" })?.value,
                  let value = Int(raw), value > offset else { return nil }
            return (value, next)
        }.min { $0.0 < $1.0 }?.1
    }

    static func notes(_ data: Data) throws -> [BooruNote] {
        let html = try BooruHTML.html(data)
        // Legacy notes store geometry in note-box divs and text in corresponding bodies.
        let divs = BooruHTML.matches("<div\\b([^>]*)>(.*?)</div>", html)
        return divs.compactMap { match in
            let attrs = BooruHTML.attributes(match[1])
            guard let raw = attrs["id"], raw.hasPrefix("note-box-"), let id = Int64(raw.dropFirst(9)), let style = attrs["style"] else { return nil }
            func dimension(_ name: String) -> Double? {
                BooruHTML.matches("(?:^|;)\\s*" + name + ":\\s*([0-9.]+)px", style).first.flatMap { Double($0[1]) }
            }
            guard let x = dimension("left"), let y = dimension("top"), let width = dimension("width"), let height = dimension("height"),
                  let body = divs.first(where: { BooruHTML.attributes($0[1])["id"] == "note-body-\(id)" }) else { return nil }
            return BooruNote(id: id, x: x, y: y, width: width, height: height, body: BooruHTML.plainText(body[2]))
        }
    }
}
