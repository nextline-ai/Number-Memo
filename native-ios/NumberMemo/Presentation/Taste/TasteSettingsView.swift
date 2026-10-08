import SwiftUI

struct TasteSettingsView: View {
    let mode: TasteMode
    var source: String = ""
    @Environment(AppEnvironment.self) private var env
    @State private var confirmReset = false
    private enum DisableTarget { case analysis }
    @State private var pendingDisable: DisableTarget?
    private var resolvedSource: String { source.isEmpty ? (mode == .comics ? "https://hitomi.la" : (env.booru.selectedServer ?? env.booru.servers.first)?.canonicalAddress ?? "") : source }
    var body: some View {
        Form {
            Section {
                NavigationLink { TasteReportsView(mode: mode, period: .week) } label: { Label(L10n.text("Weekly statistics"), systemImage: "chart.bar.xaxis") }
                    .accessibilityIdentifier("taste.settings.weekly")
                NavigationLink { TasteReportsView(mode: mode, period: .month) } label: { Label(L10n.text("Monthly Recap"), systemImage: "rectangle.stack.fill") }
                    .accessibilityIdentifier("taste.settings.monthly")
            }
            Section(L10n.text("Smart Recommendations")) {
                NavigationLink { RecommendationSettingsView(mode: mode, initialSource: resolvedSource) } label: { Label(L10n.text("Recommendation filters"), systemImage: "line.3.horizontal.decrease") }
            }
            Section(L10n.text("Taste Analysis")) {
                Toggle(L10n.text("Taste Analysis"), isOn: Binding(get: { env.taste.control.enabled }, set: { enabled in if enabled { env.taste.change { $0.enabled = true } } else { pendingDisable = .analysis } }))
                    .accessibilityIdentifier("taste.enabled")
                NavigationLink { TasteAnalysisExclusionsView(mode: mode, source: resolvedSource) } label: {
                    HStack { Text(L10n.text("Analysis excluded tags")); Spacer(); Text(String(env.taste.control.analysisExcluded(mode, source: resolvedSource).count)).foregroundStyle(.secondary) }
                }.accessibilityIdentifier("taste.settings.exclusions")
                NavigationLink {
                    List {
                        ForEach(env.taste.control.excluded.sorted(), id: \.self) { key in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(TastePresentation.name(key.components(separatedBy: "\n").last ?? key)).font(.headline)
                                Text(TastePresentation.host(key.components(separatedBy: "\n").first ?? "")).font(.caption).foregroundStyle(.secondary)
                                Button(L10n.text("Include in recommendations")) { env.taste.change { $0.excluded.remove(key) } }.font(.subheadline)
                            }.padding(.vertical, 4)
                        }
                    }.navigationTitle(L10n.text("Excluded taste tags"))
                } label: {
                    HStack { Text(L10n.text("Excluded taste tags")); Spacer(); Text(String(env.taste.control.excluded.count)).foregroundStyle(.secondary) }
                }.disabled(env.taste.control.excluded.isEmpty)
            }
            Section {
                Toggle(L10n.text("Sync analysis with iCloud"), isOn: Binding(get: { env.taste.control.cloudEnabled }, set: { enabled in env.taste.change { $0.cloudEnabled = enabled } }))
                    .accessibilityIdentifier("taste.cloud")
                Text(env.taste.cloud.status).font(.footnote).foregroundStyle(.secondary)
                if !env.sync.enabled { Text(L10n.text("iCloud sync is off. Changes cannot reach your other devices until it is enabled.")) }
                DisclosureGroup(L10n.text("Storage details")) {
                    LabeledContent(L10n.text("Analysis time zone"), value: env.taste.control.timeZone)
                    LabeledContent(L10n.text("Retention"), value: L10n.text("Until you delete it"))
                }
            } footer: { Text(L10n.text("Analysis uses your existing iCloud Drive protection. It is separate from search history retention. Other devices apply changes when they next sync.")) }
            Section {
                Button(L10n.text("Delete all analysis data"), role: .destructive) { confirmReset = true }
                    .accessibilityIdentifier("taste.reset")
                if let error = env.taste.error { Text(error).foregroundStyle(.red) }
            } footer: { Text(L10n.text("Deletes activity, preference evidence, and reports. Your saved works remain. Existing works will not be automatically analyzed again.")) }
        }.navigationTitle(L10n.text("Taste Analysis Settings"))
        .alert(L10n.text("Turn off taste analysis?"), isPresented: Binding(get: { pendingDisable != nil }, set: { if !$0 { pendingDisable = nil } }), presenting: pendingDisable) { target in
            Button(L10n.text("Keep Enabled"), role: .cancel) { pendingDisable = nil }
            Button(L10n.text("Turn Off"), role: .destructive) {
                env.taste.change { $0.enabled = false }
                pendingDisable = nil
            }
        } message: { target in
            Text(L10n.text("New taste evidence, recommendations and reports will pause. Existing analysis and saved works are kept. Your other devices apply this choice after syncing."))
        }
        .confirmationDialog(L10n.text("Delete all analysis data?"), isPresented: $confirmReset, titleVisibility: .visible) {
            Button(L10n.text("Delete all analysis data"), role: .destructive) { env.taste.reset(); Task { await env.taste.synchronize(env: env) } }
        }
    }
}

struct TasteSettingsSection: View {
    let mode: TasteMode
    var body: some View {
        Section {
            NavigationLink { TasteSettingsView(mode: mode) } label: { Label(L10n.text("Taste Analysis"), systemImage: "sparkles") }
                .accessibilityIdentifier("settings.taste")
        }
    }
}

struct BrowseFilterMenu<Content: View>: View {
    let title: String
    let icon: String
    @ViewBuilder var content: () -> Content
    var body: some View {
        Menu(content: content) {
            Label(title, systemImage: icon).font(.subheadline.weight(.medium))
                .padding(.horizontal, 12).frame(minHeight: 40)
                .background(.quaternary.opacity(0.5), in: Capsule())
        }
    }
}
struct RecommendationFilters: View {
    let mode: TasteMode
    let source: String
    var onChange: () -> Void = {}
    @Environment(AppEnvironment.self) private var env
    private var preferences: RecommendationPreferences { env.taste.control.preferences(source: source) }
    var body: some View {
        HStack {
            if mode == .comics {
                BrowseFilterMenu(title: L10n.text(preferences.language.capitalized), icon: "globe") {
                    Picker(L10n.text("Language"), selection: Binding(get: { preferences.language }, set: { language in update { $0.language = language } })) {
                        ForEach(["all", "korean", "japanese", "english"], id: \.self) { Text(L10n.text($0.capitalized)).tag($0) }
                    }
                }
            } else {
                Label(L10n.text("Recommendation filters"), systemImage: "line.3.horizontal.decrease").font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
            BrowseFilterMenu(title: preferences.sort.title(mode), icon: "arrow.up.arrow.down") {
                Picker(L10n.text("Sort"), selection: Binding(get: { preferences.sort }, set: { sort in update { $0.sort = sort } })) {
                    ForEach(RecommendationSort.options(mode)) { Text($0.title(mode)).tag($0) }
                }
            }.accessibilityIdentifier("taste.sort")
        }
    }
    private func update(_ edit: (inout RecommendationPreferences) -> Void) {
        var value = preferences; edit(&value)
        env.taste.change { $0.setPreferences(value, source: source) }; onChange()
    }
}
struct RecommendationSettingsView: View {
    let mode: TasteMode
    var initialSource: String
    @Environment(AppEnvironment.self) private var env
    @State private var selectedSource = ""
    @State private var input = ""
    private var source: String {
        if mode == .comics { return "https://hitomi.la" }
        let target = selectedSource.isEmpty ? initialSource : selectedSource
        return (env.booru.servers.first { $0.canonicalAddress == target } ?? env.booru.servers.first)?.canonicalAddress ?? ""
    }
    private var preferences: RecommendationPreferences { env.taste.control.preferences(source: source) }
    var body: some View {
        Form {
            if mode == .booru {
                Picker(L10n.text("Server"), selection: Binding(get: { source }, set: { selectedSource = $0 })) {
                    ForEach(env.booru.servers) { Text($0.displayName).tag($0.canonicalAddress) }
                }
            }
            Section { RecommendationFilters(mode: mode, source: source) }.disabled(source.isEmpty)
            Section {
                HStack {
                    TextField(L10n.text("Default included tag"), text: $input).textInputAutocapitalization(.never).autocorrectionDisabled().onSubmit(add)
                    Button(action: add) { Image(systemName: "plus.circle.fill").frame(width: 44, height: 44) }.disabled(input.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                ForEach(preferences.includedTags, id: \.self) { Text($0) }
                    .onDelete { indices in
                        var value = preferences; value.includedTags.remove(atOffsets: indices)
                        env.taste.change { $0.setPreferences(value, source: source) }
                    }
            } header: { Text(L10n.text("Default included tags")) }
            footer: { Text(L10n.text("Only this server uses these filters. All included tags must match. No language is required unless you choose one. Changes apply when you refresh recommendations.")) }
        }.disabled(source.isEmpty).navigationTitle(L10n.text("Recommendation filters"))
    }
    private func add() {
        let tag = TasteTagPolicy.normalize(input)
        guard !source.isEmpty, !tag.isEmpty, !tag.hasPrefix("-"), !preferences.includedTags.contains(tag) else { return }
        var value = preferences; value.includedTags.append(tag)
        env.taste.change { $0.setPreferences(value, source: source) }; input = ""
    }
}

extension View {
    func transientMessage(_ message: Binding<String?>) -> some View {
        overlay(alignment: .bottom) {
            if let text = message.wrappedValue {
                Text(text).font(.subheadline.weight(.medium)).multilineTextAlignment(.center)
                    .padding().background(.regularMaterial, in: Capsule()).padding()
                    .accessibilityIdentifier("sort.feedback")
                    .task(id: text) {
                        do { try await Task.sleep(for: .seconds(4)); if message.wrappedValue == text { message.wrappedValue = nil } } catch { }
                    }
            }
        }
    }
}
