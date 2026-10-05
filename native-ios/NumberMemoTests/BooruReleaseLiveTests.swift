import XCTest
import WebKit
@testable import NumberMemo

final class BooruReleaseLiveTests: XCTestCase {
    func testICloudDriveContainerUploadsIsolatedProbe() async throws {
        guard ProcessInfo.processInfo.environment["NUMBER_MEMO_BOORU_LIVE_TESTS"] == "1" else { throw XCTSkip("Opt-in iCloud verification") }
        guard FileManager.default.ubiquityIdentityToken != nil else { throw XCTSkip("No signed-in iCloud account on the test device") }
        let root = await Task.detached { FileManager.default.url(forUbiquityContainerIdentifier: AppStorage.iCloudContainerId) }.value
        let container = try XCTUnwrap(root, "The existing signing profile must allow the configured iCloud container")
        let probe = container.appendingPathComponent("Documents/NumberMemoValidation/" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: probe) }
        let file = probe.appendingPathComponent("library-probe.json")
        let document = LibrarySyncDocument(changes: [:])
        try await Task.detached { try CloudLibraryFiles.write(JSONEncoder().encode(document), to: file) }.value
        let read = try await Task.detached { try CloudLibraryFiles.read(in: probe) }.value
        XCTAssertEqual(read.count, 1)
        var uploaded = false
        for _ in 0..<200 {
            var refreshed = file
            refreshed.removeAllCachedResourceValues()
            let values = try refreshed.resourceValues(forKeys: [.ubiquitousItemIsUploadedKey, .ubiquitousItemUploadingErrorKey])
            if let error = values.ubiquitousItemUploadingError { throw error }
            if values.ubiquitousItemIsUploaded == true { uploaded = true; break }
            try await Task.sleep(for: .milliseconds(200))
        }
        if !uploaded { throw XCTSkip("Container read/write passed; iCloud upload did not finish within the verification window") }
    }

    @MainActor func testDanbooruPoolsAfterValidation() async throws {
        guard ProcessInfo.processInfo.environment["NUMBER_MEMO_BOORU_LIVE_TESTS"] == "1" else { throw XCTSkip("Opt-in public network verification") }
        let server = BooruServer.presets[0]
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = try XCTUnwrap(scene.windows.first)
        let model = BooruValidationModel(server: server)
        model.webView.frame = window.bounds; window.addSubview(model.webView)
        defer { model.webView.removeFromSuperview(); BooruWebTransport.reset(server) }
        model.load(server.baseURL.appendingPathComponent("pools"))
        for _ in 0..<300 where model.loading { try await Task.sleep(for: .milliseconds(100)) }
        if let error = model.error { throw XCTSkip("Visible website unavailable: " + error) }
        BooruWebTransport.adopt(model.webView, server: server)
        let pools = try await BooruClient.shared.pools(server: server, query: "", page: 0)
        XCTAssertFalse(pools.isEmpty)
        let next = try await BooruClient.shared.pools(server: server, query: "", page: 1)
        XCTAssertFalse(next.isEmpty)
        XCTAssertNotEqual(pools.first?.id, next.first?.id)
    }

    @MainActor func testGelbooruReportedPostAndPools() async throws {
        guard ProcessInfo.processInfo.environment["NUMBER_MEMO_BOORU_LIVE_TESTS"] == "1" else { throw XCTSkip("Opt-in public network verification") }
        let server = BooruServer.presets[1]
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = try XCTUnwrap(scene.windows.first)
        let model = BooruValidationModel(server: server)
        model.webView.frame = window.bounds; window.addSubview(model.webView)
        defer { model.webView.removeFromSuperview(); BooruWebTransport.reset(server) }
        model.load(server.pageURL(postID: 15029425))
        for _ in 0..<250 where model.loading { try await Task.sleep(for: .milliseconds(100)) }
        if model.error != nil { throw XCTSkip("The website itself closed the connection before verification; live media remains unverified") }
        BooruWebTransport.adopt(model.webView, server: server)
        let (raw, response) = try await BooruWebTransport.document(for: URLRequest(url: server.pageURL(postID: 15029425)), server: server)
        XCTAssertEqual(response.statusCode, 200)
        let html = String(decoding: raw, as: UTF8.self)
        let mediaTags = BooruHTML.matches("<(?:img|video|source)\\b[^>]*>", html).map { $0[0] }.joined(separator: "\n")
        let attachment = XCTAttachment(string: mediaTags); attachment.name = "Reported post media elements"; attachment.lifetime = .keepAlways; add(attachment)
        let post = try BooruLegacyHTML.post(raw, server: server, id: 15029425)
        XCTAssertNotNil(post.fileURL)
        let pools = try await BooruClient.shared.pools(server: server, query: "", page: 0)
        XCTAssertFalse(pools.isEmpty)
    }
}
