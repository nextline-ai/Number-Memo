import SwiftUI
import WebKit

extension Notification.Name { static let booruClientValidated = Notification.Name("booruClientValidated") }

struct BooruValidationView: View {
    let server: BooruServer
    let initialURL: URL
    @Environment(\.dismiss) private var dismiss
    @State private var model: BooruValidationModel
    init(server: BooruServer, initialURL: URL? = nil) {
        self.server = server
        self.initialURL = BooruBrowserSession.challengePage(for: server) ?? initialURL ?? server.browsingURL(query: "")
        _model = State(initialValue: BooruValidationModel(server: server))
    }
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 6) {
                    Label(model.address?.host ?? server.baseURL.host ?? server.name, systemImage: "lock.shield")
                        .font(.subheadline.weight(.semibold))
                    Text(L10n.text("Complete any verification on the website, then tap Done to retry. Cookies are saved for this server."))
                        .font(.caption).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(16)
                if model.loading { ProgressView().frame(maxWidth: .infinity).padding(4) }
                BooruValidationWebView(model: model)
                    .overlay {
                        if let error = model.error {
                            ContentFailureView(message: error) { model.load(initialURL) }
                                .frame(maxWidth: .infinity, maxHeight: .infinity).background(Color(uiColor: .systemBackground))
                        }
                    }
            }
            .navigationTitle(L10n.text("Validate Client")).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button(L10n.text("Reload"), systemImage: "arrow.clockwise") { model.load(model.address ?? initialURL) }.labelStyle(.iconOnly) }
                ToolbarItem(placement: .confirmationAction) { Button(L10n.text("Done")) { dismiss() }.accessibilityIdentifier("booru.validationDone") }
            }
            .task { model.load(initialURL) }
            .onDisappear {
                model.cancelRetries()
                if model.error == nil {
                    BooruWebTransport.adopt(model.webView, server: server)
                    BooruBrowserSession.clearChallenge(for: server)
                }
                NotificationCenter.default.post(name: .booruClientValidated, object: server.id)
            }
        }
    }
}

@MainActor @Observable
final class BooruValidationModel: NSObject, WKNavigationDelegate, WKUIDelegate {
    let server: BooruServer
    let webView: WKWebView
    var address: URL?
    var loading = false
    var error: String?
    var canGoBack = false
    var canGoForward = false
    private var retryTask: Task<Void, Never>?
    private var retryCount = 0
    private var requestedURL: URL?
    func cancelRetries() { retryTask?.cancel(); retryTask = nil }
    init(server: BooruServer) {
        self.server = server
        let config = WKWebViewConfiguration()
        config.websiteDataStore = BooruBrowserSession.dataStore(for: server)
        webView = WKWebView(frame: .zero, configuration: config)
        if #available(iOS 26.0, *) { webView.scrollView.topEdgeEffect.isHidden = true }
        super.init()
        webView.customUserAgent = BooruBrowserSession.userAgent
        webView.navigationDelegate = self; webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.accessibilityIdentifier = "booru.validationWeb"
    }
    func load(_ url: URL? = nil) {
        cancelRetries(); retryCount = 0; requestedURL = url ?? server.baseURL
        // Returning to the embedded browser reclaims its navigation delegate.
        BooruWebTransport.release(webView, server: server)
        webView.navigationDelegate = self; webView.uiDelegate = self
        error = nil; loading = true
        #if DEBUG
        if BooruUITestSupport.enabled {
            webView.loadHTMLString("<html><meta name='viewport' content='width=device-width'><body><h2>Client verification</h2><p>Validation browser is ready.</p></body></html>", baseURL: server.baseURL)
            return
        }
        #endif
        webView.load(URLRequest(url: url ?? server.baseURL))
    }
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) { loading = true; error = nil }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loading = false; address = webView.url
        canGoBack = webView.canGoBack; canGoForward = webView.canGoForward
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { failed(error) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { failed(error) }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { loading = false; error = L10n.text("Unable to Load") }
    private func failed(_ error: Error) {
        if (error as? URLError)?.code == .cancelled { return }
        if BooruConnectionRetry.isTransient(error), retryCount < 2, let url = requestedURL {
            retryCount += 1
            let delay = retryCount * 500
            loading = true; self.error = nil
            retryTask?.cancel()
            retryTask = Task { [weak self] in
                do { try await Task.sleep(for: .milliseconds(delay)) } catch { return }
                guard !Task.isCancelled else { return }
                self?.webView.load(URLRequest(url: url))
            }
            return
        }
        loading = false; self.error = BooruConnectionMessage.describe(error)
    }
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = action.request.url else { decisionHandler(.cancel); return }
        let allowed = (url.scheme == "https" && url.user == nil && url.password == nil) || url.absoluteString == "about:blank"
        if allowed && action.targetFrame == nil { webView.load(action.request); decisionHandler(.cancel) }
        else { decisionHandler(allowed ? .allow : .cancel) }
    }
}

struct BooruValidationWebView: UIViewRepresentable {
    let model: BooruValidationModel
    func makeUIView(context: Context) -> WKWebView { model.webView }
    func updateUIView(_ view: WKWebView, context: Context) {}
    // The transport retains this verified browser after dismissal.
    static func dismantleUIView(_ view: WKWebView, coordinator: ()) {}
}

struct BooruCookiesView: View {
    let server: BooruServer
    @State private var cookies: [HTTPCookie] = []
    @State private var confirmReset = false
    @State private var resetting = false
    var body: some View {
        List {
            Section {
                if cookies.isEmpty { Text(L10n.text("No Cookies")).foregroundStyle(.secondary) }
                ForEach(Array(cookies.enumerated()), id: \.offset) { _, cookie in
                    DisclosureGroup {
                        LabeledContent(L10n.text("Domain"), value: cookie.domain)
                        LabeledContent(L10n.text("Path"), value: cookie.path)
                        Text(cookie.value).font(.caption.monospaced()).textSelection(.enabled)
                        if let date = cookie.expiresDate { LabeledContent(L10n.text("Expires"), value: date.formatted()) }
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(cookie.name).font(.subheadline)
                            Text(cookie.domain).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            } header: { Text(server.name) } footer: { Text(L10n.text("Cookies are isolated from Hitomi and other Booru servers. Resetting signs you out of this server's validation browser.")) }
            Section {
                Button(L10n.text("Reset Cookies"), role: .destructive) { confirmReset = true }
                    .disabled(resetting).accessibilityIdentifier("booru.resetCookies")
            }
        }
        .navigationTitle(L10n.text("Cookies")).navigationBarTitleDisplayMode(.inline)
        .task { await reload() }
        .refreshable { await reload() }
        .confirmationDialog(L10n.text("Reset Cookies?"), isPresented: $confirmReset, titleVisibility: .visible) {
            Button(L10n.text("Reset Cookies"), role: .destructive) {
                resetting = true
                Task { await BooruBrowserSession.reset(server); await reload(); resetting = false }
            }
        } message: { Text(L10n.text("Website cookies and cached website data for this server will be removed. Your favorites and API key are kept.")) }
    }
    private func reload() async { cookies = await BooruBrowserSession.cookies(for: server).sorted { ($0.domain, $0.name) < ($1.domain, $1.name) } }
}
