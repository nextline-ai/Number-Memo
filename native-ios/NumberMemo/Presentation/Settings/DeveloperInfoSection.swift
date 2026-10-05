import SwiftUI
import WebKit

/// The same developer identity and support destinations in both library modes.
struct DeveloperInfoSection: View {
    private let website = URL(string: "https://nextline.work")!
    private let community = URL(string: "https://discord.gg/vUTGZNMaMB")!

    var body: some View {
        Section {
            HStack {
                Spacer(minLength: 0)
                DeveloperLogo().frame(width: 230, height: 64)
                    .accessibilityLabel("NextLine")
                    .accessibilityIdentifier("developer.logo")
                Spacer(minLength: 0)
            }.padding(.vertical, 8)
            LabeledContent(L10n.text("Developer"), value: "NextLine")
            LabeledContent(L10n.text("Publisher"), value: "DEAUM")
            Link(destination: website) {
                HStack(spacing: 12) {
                    Label(L10n.text("Website"), systemImage: "globe")
                    Spacer(minLength: 8)
                    Text("nextline.work").foregroundStyle(.secondary)
                    Image(systemName: "arrow.up.right").font(.caption).foregroundStyle(.secondary)
                }
            }.accessibilityIdentifier("developer.website")
            Link(destination: URL(string: "mailto:contact@nextline.work")!) {
                HStack {
                    Label(L10n.text("Email"), systemImage: "envelope")
                    Spacer()
                    Text("contact@nextline.work").foregroundStyle(.secondary)
                }
            }.accessibilityIdentifier("developer.email")
            Link(destination: community) {
                HStack(spacing: 12) {
                    Label {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(L10n.text("Community & Bug Reports"))
                            Text("Discord").font(.caption).foregroundStyle(.secondary)
                        }
                    } icon: { Image(systemName: "bubble.left.and.bubble.right") }
                    Spacer(minLength: 8)
                    Image(systemName: "arrow.up.right").font(.caption).foregroundStyle(.secondary)
                }
            }.accessibilityIdentifier("developer.community")
        } header: {
            Text(L10n.text("Developer"))
        }
    }
}

private struct DeveloperLogo: UIViewRepresentable {
    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.isOpaque = false; view.backgroundColor = .clear; view.scrollView.isScrollEnabled = false
        view.isUserInteractionEnabled = false
        if let url = Bundle.main.url(forResource: "nextline-logo", withExtension: "svg"), let svg = try? String(contentsOf: url, encoding: .utf8) {
            view.loadHTMLString("<meta name='viewport' content='width=device-width,initial-scale=1'><meta http-equiv='Content-Security-Policy' content=\"default-src 'none'; img-src data:; style-src 'unsafe-inline'\"><style>html,body{margin:0;background:transparent}svg{width:100%;height:64px}</style>" + svg, baseURL: nil)
        }
        return view
    }
    func updateUIView(_ view: WKWebView, context: Context) {}
}
