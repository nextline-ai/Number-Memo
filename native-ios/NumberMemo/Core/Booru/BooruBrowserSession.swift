import Foundation
import WebKit
import CryptoKit

/// Browser validation, API requests and media share one profile per Booru server.
/// Hitomi's default WebKit profile and shared URLSession cookie jar are never used.
@MainActor
enum BooruBrowserSession {
    private static var stores: [String: WKWebsiteDataStore] = [:]
    private static var challengedPages: [String: URL] = [:]

    static func challengePage(for server: BooruServer) -> URL? { challengedPages[server.id] }
    static func recordChallenge(_ url: URL, server: BooruServer) {
        guard BooruWebTransport.sameOrigin(url, server.baseURL) else { return }
        challengedPages[server.id] = url
    }
    static func clearChallenge(for server: BooruServer) { challengedPages.removeValue(forKey: server.id) }
    nonisolated static let userAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"

    private static var nativeAgentTask: Task<String, Never>?
    static func nativeUserAgent() async -> String {
        if let task = nativeAgentTask { return await task.value }
        let task = Task { @MainActor in
            let probe = WKWebView(frame: .zero)
            return (try? await probe.evaluateJavaScript("navigator.userAgent") as? String) ?? userAgent
        }
        nativeAgentTask = task
        return await task.value
    }

    static func dataStore(for server: BooruServer) -> WKWebsiteDataStore {
        if let store = stores[server.id] { return store }
        let store: WKWebsiteDataStore
        #if DEBUG
        if ContentUITestSupport.enabled || ContentUITestSupport.unitTestsEnabled { store = .nonPersistent() }
        else { store = WKWebsiteDataStore(forIdentifier: identifier(server.id)) }
        #else
        store = WKWebsiteDataStore(forIdentifier: identifier(server.id))
        #endif
        stores[server.id] = store
        return store
    }

    nonisolated static func identifier(_ serverID: String) -> UUID {
        let bytes = Array(SHA256.hash(data: Data(("numbermemo.booru.profile." + serverID).utf8)).prefix(16))
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7], bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    static func cookies(for server: BooruServer) async -> [HTTPCookie] {
        await dataStore(for: server).httpCookieStore.allCookies()
    }

    nonisolated static func matches(_ cookie: HTTPCookie, url: URL, now: Date = Date()) -> Bool {
        guard let host = url.host?.lowercased(), !cookie.isSecure || url.scheme == "https",
              cookie.expiresDate.map({ $0 > now }) ?? true else { return false }
        let domain = cookie.domain.lowercased()
        let bare = domain.hasPrefix(".") ? String(domain.dropFirst()) : domain
        guard host == bare || (domain.hasPrefix(".") && host.hasSuffix("." + bare)) else { return false }
        let path = url.path.isEmpty ? "/" : url.path
        return path == cookie.path || (path.hasPrefix(cookie.path) && (cookie.path.hasSuffix("/") || path.dropFirst(cookie.path.count).hasPrefix("/")))
    }

    static func prepare(_ request: URLRequest, server: BooruServer) async -> URLRequest {
        var request = request
        request.httpShouldHandleCookies = false
        request.setValue(await nativeUserAgent(), forHTTPHeaderField: "User-Agent")
        request.setValue(server.baseURL.absoluteString + "/", forHTTPHeaderField: "Referer")
        if let url = request.url {
            let matching = await cookies(for: server).filter { matches($0, url: url) }.sorted { $0.path.count > $1.path.count }
            request.setValue(matching.isEmpty ? nil : HTTPCookie.requestHeaderFields(with: matching)["Cookie"], forHTTPHeaderField: "Cookie")
        }
        return request
    }

    static func receive(_ response: URLResponse, server: BooruServer) async {
        guard let response = response as? HTTPURLResponse, let url = response.url,
              url.host == server.baseURL.host, let fields = response.allHeaderFields as? [String: String] else { return }
        let jar = dataStore(for: server).httpCookieStore
        for cookie in HTTPCookie.cookies(withResponseHeaderFields: fields, for: url) { await jar.setCookie(cookie) }
    }

    static func reset(_ server: BooruServer) async {
        clearChallenge(for: server)
        BooruWebTransport.reset(server)
        await dataStore(for: server).removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
    }
}

enum BooruConnectionMessage {
    static func describe(_ error: Error) -> String {
        if let error = error as? URLError, error.code == .secureConnectionFailed {
            return L10n.text("Unable to connect securely. Open Validate Client and complete the server’s browser check, then tap Done to retry.")
        }
        if let error = error as? URLError, error.code == .networkConnectionLost {
            return L10n.text("The server interrupted the connection. Open Validate Client, complete the browser check, then tap Done to retry.")
        }
        if (error as NSError).domain == WKError.errorDomain {
            return L10n.text("The browser connection was interrupted. Open Validate Client and try again.")
        }
        return error.localizedDescription
    }
}
