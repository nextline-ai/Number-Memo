import Foundation

/// Bounded chunked downloads. The delegate rejects foreign redirects before following them.
final class ContentTransport: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    static let shared = ContentTransport()
    private var session: URLSession!
    private let lock = NSLock()
    private var requests: [Int: Download] = [:]

    private final class Download {
        let limit: Int
        let continuation: CheckedContinuation<(Data, HTTPURLResponse), Error>
        var response: HTTPURLResponse?
        var data = Data()
        init(limit: Int, continuation: CheckedContinuation<(Data, HTTPURLResponse), Error>) {
            self.limit = limit
            self.continuation = continuation
        }
    }

    private final class Cancellation: @unchecked Sendable {
        private let lock = NSLock()
        private var task: URLSessionTask?
        private var cancelled = false
        func attach(_ task: URLSessionTask) {
            lock.withLock { self.task = task; if cancelled { task.cancel() } }
        }
        func cancel() { lock.withLock { cancelled = true; task?.cancel() } }
    }

    init(configuration: URLSessionConfiguration = .ephemeral) {
        super.init()
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 45
        configuration.httpMaximumConnectionsPerHost = 6
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }

    static func allows(_ url: URL) -> Bool {
        guard url.scheme == "https", url.user == nil, url.password == nil,
              url.port == nil || url.port == 443, let host = url.host?.lowercased() else { return false }
        if host == "tagindex.hitomi.la" { return true }
        return ["ltn", "tn", "atn", "btn", "w1", "w2", "a1", "a2"].contains { host == "\($0).gold-usergeneratedcontent.net" }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(request.url.map(Self.allows) == true ? request : nil)
    }

    func get(_ url: URL, limit: Int, range: Range<Int>? = nil, galleryID: Int64? = nil) async throws -> (Data, HTTPURLResponse) {
        guard Self.allows(url), limit > 0 else { throw URLError(.unsupportedURL) }
        try Task.checkCancellation()
        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 Version/17.0 Mobile/15E148 Safari/604.1", forHTTPHeaderField: "User-Agent")
        request.setValue(galleryID.map { "https://hitomi.la/reader/\($0).html" } ?? "https://hitomi.la/", forHTTPHeaderField: "Referer")
        if let range { request.setValue("bytes=\(range.lowerBound)-\(range.upperBound - 1)", forHTTPHeaderField: "Range") }
        let cancellation = Cancellation()
        return try await withTaskCancellationHandler {
            let result: (Data, HTTPURLResponse) = try await withCheckedThrowingContinuation { continuation in
                let task = session.dataTask(with: request)
                lock.withLock { requests[task.taskIdentifier] = Download(limit: limit, continuation: continuation) }
                cancellation.attach(task)
                task.resume()
            }
            try Task.checkCancellation()
            return result
        } onCancel: { cancellation.cancel() }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let download = lock.withLock({ requests[dataTask.taskIdentifier] }), let http = response as? HTTPURLResponse else {
            finish(dataTask, error: ContentError.invalidResponse); completionHandler(.cancel); return
        }
        guard [200, 206, 416].contains(http.statusCode) else {
            finish(dataTask, error: ContentError.unavailable(http.statusCode)); completionHandler(.cancel); return
        }
        download.response = http
        if http.statusCode == 416 { finish(dataTask); completionHandler(.cancel); return }
        guard response.expectedContentLength <= Int64(download.limit) else {
            finish(dataTask, error: ContentError.tooLarge); completionHandler(.cancel); return
        }
        download.data.reserveCapacity(min(download.limit, max(0, Int(response.expectedContentLength))))
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let download = lock.withLock({ requests[dataTask.taskIdentifier] }) else { return }
        guard data.count <= download.limit - download.data.count else {
            finish(dataTask, error: ContentError.tooLarge); dataTask.cancel(); return
        }
        download.data.append(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) { finish(task, error: error) }

    // URLSession's delegate queue is serial; only dictionary registration/removal crosses queues.
    private func finish(_ task: URLSessionTask, error: Error? = nil) {
        guard let download = lock.withLock({ requests.removeValue(forKey: task.taskIdentifier) }) else { return }
        if let error { download.continuation.resume(throwing: error) }
        else if let response = download.response { download.continuation.resume(returning: (download.data, response)) }
        else { download.continuation.resume(throwing: ContentError.invalidResponse) }
    }
}
