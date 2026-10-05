import SwiftUI

struct ReaderSettingsSection: View {
    let booru: Bool
    @Binding var isPresented: Bool
    var body: some View {
        Section {
            Button { isPresented = true } label: {
                HStack {
                    Label { Text(L10n.text("Reader Settings")).foregroundStyle(.primary) } icon: { Image(systemName: "slider.horizontal.3") }
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                }
            }.accessibilityIdentifier(booru ? "booru.readerSettings" : "settings.reader")
        } header: { Text(L10n.text("Viewer")) } footer: {
            Text(L10n.text("Appearance and reader preferences are saved separately for each mode."))
        }
    }
}

struct SettingsSupportSection: View {
    @Binding var showOnboarding: Bool
    var body: some View {
        Section(L10n.text("Help & Privacy")) {
            Button(L10n.text("Replay Onboarding"), systemImage: "sparkles") { showOnboarding = true }
                .accessibilityIdentifier("settings.onboarding")
            NavigationLink { PrivacyPolicyView() } label: {
                Label(L10n.text("Privacy Policy"), systemImage: "hand.raised")
            }.accessibilityIdentifier("settings.privacy")
            NavigationLink { AcknowledgmentsView() } label: {
                Label(L10n.text("Open Source Licenses"), systemImage: "doc.text")
            }
            LabeledContent(L10n.text("Version"), value: version)
        }
    }
    private var version: String {
        let info = Bundle.main.infoDictionary ?? [:]
        return "\(info["CFBundleShortVersionString"] as? String ?? "") (\(info["CFBundleVersion"] as? String ?? ""))"
    }
}

struct PrivacyPolicyView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text(policy).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                Link(L10n.text("View Online"), destination: URL(string: "https://github.com/nextline-ai/Number-Memo/blob/main/docs/privacy-policy.md")!)
                Link("contact@nextline.work", destination: URL(string: "mailto:contact@nextline.work")!)
            }.padding(20)
        }.navigationTitle(L10n.text("Privacy Policy")).navigationBarTitleDisplayMode(.inline)
            .accessibilityIdentifier("settings.privacyPolicy")
    }
    private var policy: String {
        guard let url = Bundle.main.url(forResource: "PrivacyPolicy", withExtension: "txt", subdirectory: nil, localization: L10n.language),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return L10n.text("Unable to load privacy policy.") }
        return text
    }
}

/// Reports are explicitly composed and sent by the user, never submitted automatically.
struct ContentReportView: View {
    let page: URL
    var body: some View {
        List {
            Section {
                Text(L10n.text("Include what is wrong with this content. Your mail app opens a draft containing the page address; nothing is sent until you send it."))
                Link(L10n.text("Report by Email"), destination: mailURL)
                    .accessibilityIdentifier("content.reportEmail")
                Link(L10n.text("Open on Website"), destination: page)
                Text(page.absoluteString).font(.footnote).textSelection(.enabled)
            } footer: {
                Text(L10n.text("NextLine can investigate app behavior. The source website controls its posts; use its reporting tools to request removal there."))
            }
            Section { Text("contact@nextline.work").textSelection(.enabled) }
        }.navigationTitle(L10n.text("Report Content")).navigationBarTitleDisplayMode(.inline)
    }
    private var mailURL: URL {
        var url = URLComponents(string: "mailto:contact@nextline.work")!
        url.queryItems = [.init(name: "subject", value: "Number Memo — Content report"), .init(name: "body", value: page.absoluteString + "\n\n")]
        return url.url!
    }
}

private struct AcknowledgmentsView: View {
    var body: some View {
        ScrollView {
            Text(license).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(20)
        }.navigationTitle(L10n.text("Open Source Licenses")).navigationBarTitleDisplayMode(.inline)
    }
    private var license: String {
        guard let url = Bundle.main.url(forResource: "Acknowledgments", withExtension: "txt"), let text = try? String(contentsOf: url, encoding: .utf8) else { return "GRDB.swift" }
        return text
    }
}
