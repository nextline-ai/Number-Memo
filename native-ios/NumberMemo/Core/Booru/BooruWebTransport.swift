import Foundation
import WebKit

/// Keep requests in WebKit after validation: some servers bind clearance to the
/// browser's TLS connection characteristics, not just its Cookie header.
@MainActor
enum BooruWebTransport {
    private static var sessions: [String: Browser] = [:]

    static func hasSession(for server: BooruServer) -> Bool { sessions[server.id] != nil }

    static func adopt(_ webView: WKWebView, server: BooruServer) {
        // A usable page may keep loading ads/subresources. Keep the actual validated
        // view even then, rather than silently replacing it with a cold browser.
        guard let url = webView.url, sameOrigin(url, server.baseURL) else { return }
        sessions[server.id] = Browser(server: server, webView: webView)
    }

    static func reset(_ server: BooruServer) {
        if let browser = sessions.removeValue(forKey: server.id) {
            browser.navigationTask?.cancel()
            browser.webView.stopLoading()
        }
    }

    static func release(_ webView: WKWebView, server: BooruServer) {
        if let browser = sessions[server.id], browser.webView === webView {
            browser.navigationTask?.cancel()
            sessions.removeValue(forKey: server.id)
        }
    }

    nonisolated static func sameOrigin(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.scheme == "https" && rhs.scheme == "https" && lhs.host?.lowercased() == rhs.host?.lowercased()
            && (lhs.port ?? 443) == (rhs.port ?? 443) && lhs.user == nil && lhs.password == nil
    }

    static func data(for request: URLRequest, server: BooruServer) async throws -> (Data, HTTPURLResponse) {
        guard let url = request.url, sameOrigin(url, server.baseURL) else { throw BooruError.invalidServer }
        let browser: Browser
        if let existing = sessions[server.id] { browser = existing }
        else {
            browser = Browser(server: server)
            sessions[server.id] = browser
        }
        return try await browser.enqueue { try await retryConnection { try await fetch(request, url: url, browser: browser) } }
    }

    private static func retryConnection<T>(_ operation: () async throws -> T) async throws -> T {
        for attempt in 0..<3 {
            do { return try await operation() }
            catch {
                try Task.checkCancellation()
                guard attempt < 2, BooruConnectionRetry.isTransient(error) else { throw error }
                try await Task.sleep(for: .milliseconds(500 * (attempt + 1)))
            }
        }
        throw URLError(.cannotConnectToHost)
    }

    private static func fetch(_ request: URLRequest, url: URL, browser: Browser) async throws -> (Data, HTTPURLResponse) {
        try await browser.ready()
        try Task.checkCancellation()
        // The isolated content world prevents page scripts from inspecting API credentials
        // or replacing fetch. Redirects are rejected before credentials can leave this origin.
        let value = try await browser.webView.callAsyncJavaScript("""
            const target = new URL(address);
            if (target.origin !== location.origin || target.protocol !== 'https:') throw new Error('Origin mismatch');
            const controller = new AbortController();
            const timer = setTimeout(() => controller.abort(), 25000);
            try {
                const response = await fetch(target.href, {method: 'GET', headers,
                    credentials: 'include', redirect: 'error', signal: controller.signal});
                const reader = response.body.getReader();
                const decoder = new TextDecoder();
                let body = '', size = 0;
                while (true) {
                    const chunk = await reader.read();
                    if (chunk.done) break;
                    size += chunk.value.byteLength;
                    if (size > 12000000) { await reader.cancel(); throw new Error('Response too large'); }
                    body += decoder.decode(chunk.value, {stream: true});
                }
                body += decoder.decode();
                return {status: response.status, body};
            } catch (error) {
                if (error.name === 'AbortError') return {networkError: 'timeout'};
                if (error.name === 'TypeError') return {networkError: 'connection'};
                throw error;
            } finally { clearTimeout(timer); }
            """, arguments: ["address": url.absoluteString,
                             "headers": request.allHTTPHeaderFields?.filter { ["accept", "authorization"].contains($0.key.lowercased()) } ?? [:]],
            in: nil, contentWorld: .defaultClient)
        try Task.checkCancellation()
        if let result = value as? [String: Any], let failure = result["networkError"] as? String {
            throw URLError(failure == "timeout" ? .timedOut : .networkConnectionLost)
        }
        guard let result = value as? [String: Any], let status = result["status"] as? Int,
              let body = result["body"] as? String,
              let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil) else {
            throw BooruError.invalidResponse
        }
        return (Data(body.utf8), response)
    }

    /// Public galleries sometimes allow document navigation while rejecting DAPI/XHR.
    /// Read the rendered document in the validated browser, with serialized navigation.
    static func document(for request: URLRequest, server: BooruServer) async throws -> (Data, HTTPURLResponse) {
        guard let url = request.url, sameOrigin(url, server.baseURL) else { throw BooruError.invalidServer }
        let browser = sessions[server.id] ?? Browser(server: server)
        sessions[server.id] = browser
        return try await browser.enqueue { try await retryConnection { try await browser.document(at: url) } }
    }

    static func imageData(url: URL, server: BooruServer) async throws -> Data {
        guard url.scheme == "https", url.user == nil, url.password == nil else { throw BooruError.invalidServer }
        let browser = sessions[server.id] ?? Browser(server: server)
        sessions[server.id] = browser
        return try await browser.enqueue { try await fetchImage(url: url, browser: browser) }
    }
    private static func fetchImage(url: URL, browser: Browser) async throws -> Data {
        try await browser.ready()
        let result = try await browser.webView.callAsyncJavaScript("""
            const target = new URL(address);
            const controller = new AbortController();
            const timer = setTimeout(() => controller.abort(), 25000);
            try {
                const response = await fetch(target.href, {credentials: target.origin === location.origin ? 'include' : 'omit',
                    redirect: 'error', signal: controller.signal});
                if (!response.ok) throw new Error('Image unavailable');
                const reader = response.body.getReader();
                let size = 0, chunks = [];
                while (true) {
                    const chunk = await reader.read();
                    if (chunk.done) break;
                    size += chunk.value.byteLength;
                    if (size > 64000000) { await reader.cancel(); throw new Error('Image too large'); }
                    chunks.push(chunk.value);
                }
                const blob = new Blob(chunks);
                return await new Promise((resolve, reject) => {
                    const file = new FileReader(); file.onload = () => resolve(file.result);
                    file.onerror = reject; file.readAsDataURL(blob);
                });
            } finally { clearTimeout(timer); }
            """, arguments: ["address": url.absoluteString], in: nil, contentWorld: .defaultClient)
        try Task.checkCancellation()
        guard let text = result as? String, let comma = text.firstIndex(of: ","),
              let data = Data(base64Encoded: String(text[text.index(after: comma)...])) else { throw BooruError.invalidResponse }
        return data
    }

    private final class Browser: NSObject, WKNavigationDelegate {
        let webView: WKWebView
        let server: BooruServer
        var failure: Error?
        var navigationTask: Task<Void, Never>?
        func enqueue<T>(_ operation: @escaping @MainActor () async throws -> T) async throws -> T {
            let previous = navigationTask
            let task = Task { @MainActor in
                await previous?.value
                try Task.checkCancellation()
                return try await operation()
            }
            navigationTask = Task { _ = await task.result }
            return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
        }
        var committed = false
        var documentResponse: HTTPURLResponse?
        init(server: BooruServer, webView adopted: WKWebView? = nil) {
            self.server = server
            if let adopted { webView = adopted }
            else {
                let configuration = WKWebViewConfiguration()
                configuration.websiteDataStore = BooruBrowserSession.dataStore(for: server)
                webView = WKWebView(frame: .zero, configuration: configuration)
            }
            super.init()
            committed = adopted != nil
            webView.navigationDelegate = self
            webView.uiDelegate = nil
            if adopted == nil { webView.load(URLRequest(url: server.baseURL)) }
        }
        func ready() async throws {
            if failure != nil {
                failure = nil; committed = false
                webView.load(URLRequest(url: server.baseURL))
            }
            for _ in 0..<250 {
                try Task.checkCancellation()
                if let failure { throw failure }
                if committed, let url = webView.url {
                    guard BooruWebTransport.sameOrigin(url, server.baseURL) else { throw BooruError.validationRequired }
                    let ready = try? await webView.evaluateJavaScript("document.readyState !== 'loading'", in: nil, contentWorld: .defaultClient)
                    if ready as? Bool == true { return }
                }
                try await Task.sleep(for: .milliseconds(100))
            }
            throw URLError(.timedOut)
        }
        func document(at url: URL) async throws -> (Data, HTTPURLResponse) {
            failure = nil; committed = false; documentResponse = nil
            var request = URLRequest(url: url)
            request.setValue(server.baseURL.absoluteString + "/", forHTTPHeaderField: "Referer")
            if let current = webView.url, BooruWebTransport.sameOrigin(current, server.baseURL) {
                // Follow the page as a normal same-origin navigation, preserving the
                // browser's referrer and navigation context across gallery pages.
                let encoded = String(decoding: try JSONEncoder().encode(url.absoluteString), as: UTF8.self)
                // A navigation destroys the JS context. Do not await an async JS
                // function across that destruction (WebKit reports a script error).
                webView.evaluateJavaScript("location.assign(" + encoded + ");", in: nil, in: .defaultClient) { [weak self] result in
                    guard let self else { return }
                    if case .failure = result, !self.committed { self.webView.load(request) }
                }
            } else { webView.load(request) }
            var lastChallenge: (Data, HTTPURLResponse)?
            for _ in 0..<300 {
                try Task.checkCancellation()
                if let failure { throw failure }
                if committed, let response = documentResponse,
                   let current = webView.url, BooruWebTransport.sameOrigin(current, server.baseURL) {
                    let value = try? await webView.evaluateJavaScript("document.readyState === 'loading' ? null : document.documentElement.outerHTML", in: nil, contentWorld: .defaultClient)
                    if let html = value as? String {
                        guard html.utf8.count < 12_000_000 else { throw BooruError.invalidResponse }
                        let data = Data(html.utf8)
                        if BooruClient.needsBrowser(data, response: response) {
                            // Let the website finish its normal navigation/scripts. Interactive
                            // checks still require the visible Validate Client browser.
                            lastChallenge = (data, response)
                        } else { return (data, response) }
                    }
                }
                try await Task.sleep(for: .milliseconds(100))
            }
            if let lastChallenge { return lastChallenge }
            throw URLError(.timedOut)
        }
        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) { committed = true }
        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) { committed = false }
        func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
            if response.isForMainFrame { documentResponse = response.response as? HTTPURLResponse }
            decisionHandler(.allow)
        }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            if (error as? URLError)?.code != .cancelled { failure = error }
        }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            if (error as? URLError)?.code != .cancelled { failure = error }
        }
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { failure = URLError(.networkConnectionLost) }
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let url = action.request.url else { decisionHandler(.cancel); return }
            if action.targetFrame?.isMainFrame == false {
                decisionHandler(url.scheme == "https" || url.absoluteString == "about:blank" ? .allow : .cancel)
            } else { decisionHandler(BooruWebTransport.sameOrigin(url, server.baseURL) ? .allow : .cancel) }
        }
    }
}

/// Retry only transport failures; login, challenges and HTTP errors need their own UI.
enum BooruConnectionRetry {
    static func isTransient(_ error: Error) -> Bool {
        guard let network = error as? URLError else { return false }
        return [.secureConnectionFailed, .networkConnectionLost, .timedOut, .cannotConnectToHost].contains(network.code)
    }
}
