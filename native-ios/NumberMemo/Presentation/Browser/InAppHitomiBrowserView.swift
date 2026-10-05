import SwiftUI
import WebKit

/// Emergency website access, independent of the native metadata and image adapters.
/// Restores the WKWebView approach from main without its reader-specific DOM scripts.
struct InAppHitomiBrowserView: View {
    @Environment(\.dismiss) private var dismiss
    let embedded: Bool
    @State private var model: EmbeddedBrowserModel

    init(initialUrl: String = HitomiUrls.home, embedded: Bool = false) {
        self.embedded = embedded
        _model = State(initialValue: EmbeddedBrowserModel(initialUrl: initialUrl))
    }

    var body: some View {
        VStack(spacing: 0) {
            if !embedded { HStack {
                if !embedded {
                    Button(L10n.text("Close"), systemImage: "xmark") { dismiss() }
                        .labelStyle(.iconOnly).accessibilityIdentifier("browser.close")
                }
                Spacer()
                VStack(spacing: 2) {
                    Text(model.title.isEmpty ? L10n.text("Built-in Browser") : model.title)
                        .font(.subheadline.bold()).lineLimit(1)
                    Text(model.address?.host ?? "hitomi.la").font(.caption).foregroundStyle(.secondary)
                        .accessibilityIdentifier("browser.address")
                        .accessibilityValue(model.address?.absoluteString ?? model.initialUrl)
                }
                Spacer()
            }.padding(12) }
            if model.loading { ProgressView().frame(maxWidth: .infinity).padding(4) }
            BrowserWebView(model: model)
                .overlay {
                    if let error = model.error {
                        ContentFailureView(message: error) { model.reload() }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(Color(uiColor: .systemBackground))
                    }
                }
            Divider()
            HStack {
                Button(L10n.text("Back"), systemImage: "chevron.backward") { model.webView.goBack() }
                    .disabled(!model.canGoBack).accessibilityIdentifier("browser.back")
                Spacer()
                Button(L10n.text("Forward"), systemImage: "chevron.forward") { model.webView.goForward() }
                    .disabled(!model.canGoForward).accessibilityIdentifier("browser.forward")
                Spacer()
                Button(L10n.text("Reload"), systemImage: "arrow.clockwise") { model.reload() }
                    .accessibilityIdentifier("browser.reload")
            }.labelStyle(.iconOnly).buttonStyle(.borderless).padding(.horizontal, 24).padding(.vertical, 12)
        }.background(Color(uiColor: .systemBackground))
            .toolbar {
                if embedded {
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            Text(model.title.isEmpty ? L10n.text("Built-in Browser") : model.title)
                            Text(model.address?.absoluteString ?? model.initialUrl)
                            if let address = model.address { ShareLink(item: address) }
                        } label: { Image(systemName: "info.circle").frame(width: 32, height: 32) }
                            .accessibilityLabel(model.address?.host ?? "hitomi.la")
                            .accessibilityIdentifier("browser.address")
                            .accessibilityValue(model.address?.absoluteString ?? model.initialUrl)
                    }
                }
            }
    }
}

@MainActor @Observable
final class EmbeddedBrowserModel: NSObject, WKNavigationDelegate, WKUIDelegate {
    let initialUrl: String
    let webView: WKWebView
    var title = ""
    var address: URL?
    var loading = false
    var canGoBack = false
    var canGoForward = false
    var error: String?

    init(initialUrl: String) {
        self.initialUrl = initialUrl
        let configuration = WKWebViewConfiguration()
        #if DEBUG
        if ContentUITestSupport.enabled {
            configuration.websiteDataStore = .nonPersistent()
            configuration.setURLSchemeHandler(BrowserFixtureHandler(), forURLScheme: "numbermemo-browser-test")
        }
        #endif
        webView = WKWebView(frame: .zero, configuration: configuration)
        if #available(iOS 26.0, *) { webView.scrollView.topEdgeEffect.isHidden = true }
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.accessibilityIdentifier = "browser.webview"
    }

    static func allows(_ url: URL) -> Bool {
        ["https", "http"].contains(url.scheme?.lowercased() ?? "") && url.host != nil && url.user == nil && url.password == nil
    }

    func start() {
        guard let url = URL(string: initialUrl), Self.allows(url) else {
            error = L10n.text("Invalid Address"); return
        }
        #if DEBUG
        if ContentUITestSupport.enabled, var components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            components.scheme = "numbermemo-browser-test"
            if let fixture = components.url { webView.load(URLRequest(url: fixture)); return }
        }
        #endif
        webView.load(URLRequest(url: url))
    }

    func reload() {
        error = nil
        if webView.url == nil { start() } else { webView.reload() }
    }

    private func update(_ webView: WKWebView) {
        title = webView.title ?? ""
        address = webView.url
        canGoBack = webView.canGoBack
        canGoForward = webView.canGoForward
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        loading = true; error = nil
    }
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) { update(webView) }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { loading = false; update(webView) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { failed(error) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { failed(error) }
    private func failed(_ failure: Error) {
        guard (failure as? URLError)?.code != .cancelled else { return }
        loading = false; error = L10n.text("Unable to load. Check your connection and try again.")
        update(webView)
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        loading = false; error = L10n.text("Unable to load. Check your connection and try again.")
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else { decisionHandler(.cancel); return }
        #if DEBUG
        if ContentUITestSupport.enabled && url.scheme == "numbermemo-browser-test" { decisionHandler(.allow); return }
        #endif
        decisionHandler(Self.allows(url) || (url.absoluteString == "about:blank" && navigationAction.targetFrame?.isMainFrame == false) ? .allow : .cancel)
    }
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        // User-tapped new-window links stay inside the app; unsolicited popups are ignored.
        if navigationAction.navigationType == .linkActivated { webView.load(navigationAction.request) }
        return nil
    }
}

private struct BrowserWebView: UIViewRepresentable {
    let model: EmbeddedBrowserModel
    func makeUIView(context: Context) -> WKWebView {
        model.webView.navigationDelegate = model
        model.webView.uiDelegate = model
        if model.webView.url == nil { model.start() }
        return model.webView
    }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
    static func dismantleUIView(_ uiView: WKWebView, coordinator: ()) {
        uiView.stopLoading(); uiView.navigationDelegate = nil; uiView.uiDelegate = nil
    }
}

#if DEBUG
/// Local HTML exercises real WebKit navigation without browsing private content or making network requests.
private final class BrowserFixtureHandler: NSObject, WKURLSchemeHandler {
    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        let url = urlSchemeTask.request.url!
        let second = url.path == "/second"
        let html = """
        <!doctype html><meta name="viewport" content="width=device-width, initial-scale=1">
        <title>Browser fixture</title><body style="font:24px -apple-system;padding:24px">
        <h1>\(second ? "Second page" : "Browser ready")</h1>
        <a href="/second">Next test page</a><p><a target="_blank" href="/third">New-window test page</a></p>
        <p id="script">JavaScript pending</p><script>document.getElementById('script').textContent='JavaScript ready';</script>
        </body>
        """
        let data = Data(html.utf8)
        urlSchemeTask.didReceive(URLResponse(url: url, mimeType: "text/html", expectedContentLength: data.count, textEncodingName: "utf-8"))
        urlSchemeTask.didReceive(data); urlSchemeTask.didFinish()
    }
    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {}
}
#endif
