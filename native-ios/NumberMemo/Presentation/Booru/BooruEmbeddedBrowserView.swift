import SwiftUI
import WebKit

/// A full website fallback with the same isolated cookie profile as Validate Client.
struct BooruEmbeddedBrowserView: View {
    let servers: [BooruServer]
    let query: String
    let poolID: Int64?
    let sort: BooruSort
    let rating: BooruRating
    var preferredServerID: String?
    @State private var selectedID: String?
    @SwiftUI.AppStorage("booru.useEmbeddedBrowser", store: ReaderPreferences.booruDefaults) private var useEmbeddedBrowser = false
    private var server: BooruServer? { servers.first { $0.id == (selectedID ?? preferredServerID) } ?? servers.first }
    var body: some View {
        if let server {
            VStack(spacing: 0) {
                HStack {
                    Menu {
                        ForEach(servers) { value in
                            Button { selectedID = value.id } label: {
                                Label(value.name, systemImage: value.id == server.id ? "checkmark" : "globe")
                            }
                        }
                    } label: { Label(server.name, systemImage: "globe").lineLimit(1) }
                        .accessibilityIdentifier("booru.browserServer")
                    Spacer()
                    Button(L10n.text("Show Image Grid"), systemImage: "square.grid.2x2") { useEmbeddedBrowser = false }
                        .labelStyle(.iconOnly).accessibilityIdentifier("booru.nativeGrid")
                }.font(.subheadline).padding(.horizontal, 20).frame(height: 44)
                BooruWebsiteView(server: server, url: server.browsingURL(query: sort.query(rating.query(query, server: server), engine: server.engine), poolID: poolID))
                    .id(server.id)
            }
        } else { ContentUnavailableView(L10n.text("No Servers"), systemImage: "globe") }
    }
}

private struct BooruWebsiteView: View {
    let server: BooruServer
    let url: URL
    @State private var model: BooruValidationModel
    @State private var loadedURL: URL?
    init(server: BooruServer, url: URL) {
        self.server = server; self.url = url
        _model = State(initialValue: BooruValidationModel(server: server))
    }
    var body: some View {
        VStack(spacing: 0) {
            if model.loading { ProgressView().frame(maxWidth: .infinity).frame(height: 4) }
            BooruValidationWebView(model: model)
                .accessibilityIdentifier("booru.embeddedWeb")
                .overlay {
                    if let error = model.error {
                        ContentFailureView(message: error) { model.load(url) }
                            .frame(maxWidth: .infinity, maxHeight: .infinity).background(Color(uiColor: .systemBackground))
                    }
                }
            HStack(spacing: 24) {
                Button(L10n.text("Back"), systemImage: "chevron.left") { model.webView.goBack() }.disabled(!model.canGoBack)
                Button(L10n.text("Forward"), systemImage: "chevron.right") { model.webView.goForward() }.disabled(!model.canGoForward)
                Spacer(minLength: 8)
                Text(model.address?.host ?? server.baseURL.host ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 8)
                Button(L10n.text("Reload"), systemImage: "arrow.clockwise") { model.load(model.address ?? url) }
                ShareLink(item: model.address ?? url)
            }.labelStyle(.iconOnly).padding(.horizontal, 20).frame(height: 44)
        }
        .task(id: url) {
            model.load(loadedURL == url ? model.address ?? url : url)
            loadedURL = url
        }
        .onDisappear {
            model.cancelRetries()
            if model.canAdoptSession { BooruWebTransport.adopt(model.webView, server: server) }
        }
    }
}
