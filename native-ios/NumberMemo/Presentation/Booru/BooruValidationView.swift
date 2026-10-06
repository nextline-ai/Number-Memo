import SwiftUI
import WebKit

extension Notification.Name { static let booruClientValidated = Notification.Name("booruClientValidated") }

struct BooruValidationView: View {
    let server: BooruServer
    let initialURL: URL
    @Environment(\.dismiss) private var dismiss
    @State private var confirmReset = false
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
                    Label(model.address?.host ?? server.baseURL.host ?? server.displayName, systemImage: "lock.shield")
                        .font(.subheadline.weight(.semibold))
                    Text(L10n.text("Complete any verification on the website, then tap Done to retry. Cookies are saved for this server."))
                        .font(.caption).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(16)
                if model.challengeStalled {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(L10n.text("Verification is taking longer than expected. Reload, or reset this website’s cookies and try again."))
                            .font(.footnote)
                        HStack {
                            Button(L10n.text("Reload")) { model.load(model.address ?? initialURL) }
                            Button(L10n.text("Reset Cookies"), role: .destructive) { confirmReset = true }
                            Link(L10n.text("Open in Browser"), destination: server.baseURL)
                        }.font(.footnote)
                    }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
                }
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
            .confirmationDialog(L10n.text("Reset Cookies?"), isPresented: $confirmReset, titleVisibility: .visible) {
                Button(L10n.text("Reset Cookies"), role: .destructive) {
                    Task { await BooruBrowserSession.reset(server); model.load(initialURL) }
                }
            } message: { Text(L10n.text("Website cookies and cached website data for this server will be removed. Your favorites and API key are kept.")) }
            .onDisappear {
                model.cancelRetries()
                if model.canAdoptSession {
                    BooruWebTransport.adopt(model.webView, server: server)
                    BooruBrowserSession.clearChallenge(for: server)
                    NotificationCenter.default.post(name: .booruClientValidated, object: server.id)
                }
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
    var challengeStalled = false
    private(set) var challengePresent = false
    private var inspectedPage = false
    var canAdoptSession: Bool { inspectedPage && error == nil && !challengePresent && address.map { BooruWebTransport.sameOrigin($0, server.baseURL) } == true }
    private var monitorTask: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?
    private var retryCount = 0
    private var requestedURL: URL?
    func cancelRetries() { retryTask?.cancel(); retryTask = nil; monitorTask?.cancel(); monitorTask = nil }
    init(server: BooruServer) {
        self.server = server
        let config = WKWebViewConfiguration()
        config.websiteDataStore = BooruBrowserSession.dataStore(for: server)
        webView = WKWebView(frame: .zero, configuration: config)
        if #available(iOS 26.0, *) { webView.scrollView.topEdgeEffect.isHidden = true }
        super.init()
        webView.navigationDelegate = self; webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.accessibilityIdentifier = "booru.validationWeb"
    }
    func load(_ url: URL? = nil) {
        cancelRetries(); retryCount = 0; requestedURL = url ?? server.baseURL
        // Returning to the embedded browser reclaims its navigation delegate.
        BooruWebTransport.release(webView, server: server)
        webView.navigationDelegate = self; webView.uiDelegate = self
        error = nil; loading = true; challengeStalled = false; challengePresent = false; inspectedPage = false
        monitorTask = Task { [weak self] in
            let start = Date()
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
                guard let self else { return }
                await self.inspectChallenge()
                if Date().timeIntervalSince(start) >= 25 && (self.challengePresent || !self.inspectedPage || self.loading) {
                    self.challengeStalled = true
                    self.loading = false
                } else if self.inspectedPage && !self.challengePresent && !self.loading { self.challengeStalled = false }
            }
        }
        #if DEBUG
        if BooruUITestSupport.enabled {
            webView.loadHTMLString("<html><meta name='viewport' content='width=device-width'><body><h2>Client verification</h2><p>Validation browser is ready.</p></body></html>", baseURL: server.baseURL)
            return
        }
        #endif
        webView.load(URLRequest(url: url ?? server.baseURL))
    }
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) { loading = true; error = nil; inspectedPage = false }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loading = false; address = webView.url
        canGoBack = webView.canGoBack; canGoForward = webView.canGoForward
        Task { await inspectChallenge() }
    }
    private func inspectChallenge() async {
        guard let url = webView.url, BooruWebTransport.sameOrigin(url, server.baseURL) else { return }
        let result = try? await webView.evaluateJavaScript("""
            (() => {
                if (document.readyState === 'loading') return null;
                return !!document.querySelector('#challenge-form, #challenge-running, #challenge-stage')
                    || /^(just a moment|checking your browser|attention required)/i.test(document.title);
            })()
            """)
        guard webView.url == url, let present = result as? Bool else { return }
        inspectedPage = true; address = url; challengePresent = present
        if !present { challengeStalled = false }
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
            } header: { Text(server.displayName) } footer: { Text(L10n.text("Cookies are isolated from Hitomi and other Booru servers. Resetting signs you out of this server's validation browser.")) }
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
