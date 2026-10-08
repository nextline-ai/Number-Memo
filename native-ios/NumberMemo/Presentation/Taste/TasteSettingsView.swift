import SwiftUI

struct TasteSettingsView: View {
    let mode: TasteMode
    @Environment(AppEnvironment.self) private var env
    @State private var confirmReset = false
    private enum DisableTarget { case analysis, ai }
    @State private var pendingDisable: DisableTarget?
    var body: some View {
        Form {
            Section {
                NavigationLink { TasteReportsView(mode: mode, period: .week) } label: { Label(L10n.text("Weekly statistics"), systemImage: "chart.bar.xaxis") }
                    .accessibilityIdentifier("taste.settings.weekly")
                NavigationLink { TasteReportsView(mode: mode, period: .month) } label: { Label(L10n.text("Monthly Recap"), systemImage: "rectangle.stack.fill") }
                    .accessibilityIdentifier("taste.settings.monthly")
            }
            Section(L10n.text("Taste Analysis")) {
                Toggle(L10n.text("Taste Analysis"), isOn: Binding(get: { env.taste.control.enabled }, set: { enabled in if enabled { env.taste.change { $0.enabled = true } } else { pendingDisable = .analysis } }))
                    .accessibilityIdentifier("taste.enabled")
                NavigationLink { TasteAnalysisExclusionsView(mode: mode) } label: {
                    HStack { Text(L10n.text("Analysis excluded tags")); Spacer(); Text(String(env.taste.control.analysisExcluded(mode).count)).foregroundStyle(.secondary) }
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
                Toggle(L10n.text("On-device AI explanations"), isOn: Binding(get: { env.taste.control.aiEnabled }, set: { enabled in if enabled { env.taste.change { $0.aiEnabled = true } } else { pendingDisable = .ai } }))
                    .accessibilityIdentifier("taste.ai")
                Label(L10n.text("Private by design, processed on your device"), systemImage: "lock.shield").font(.subheadline.weight(.semibold))
                Text(L10n.text("AI runs on this device. It receives only temporary identifiers and statistics, never your original tags, searches, images or titles. AI requests are not sent to a cloud model."))
                    .font(.footnote).foregroundStyle(.secondary)
                Text(L10n.text("When enabled, iCloud sync uses iCloud Drive encryption. Recommendation searches send selected tags to the connected content website."))
                    .font(.footnote).foregroundStyle(.secondary)
                Text(OnDeviceInsightService.availabilityMessage).font(.footnote).foregroundStyle(.secondary)
                Text(L10n.text("AI results are reused, with up to 3 generations in any 5-minute window. No waiting is required between allowed generations. AI pauses in Low Power Mode or in the background. Statistical recommendations remain available."))
                    .font(.footnote).foregroundStyle(.secondary)
            } footer: { Text(L10n.text("Search context and saved works build your profile. Opened works only provide a comparison sample. Technical and management tags are excluded.")) }
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
        .alert(L10n.text(pendingDisable == .analysis ? "Turn off taste analysis?" : "Turn off on-device AI explanations?"), isPresented: Binding(get: { pendingDisable != nil }, set: { if !$0 { pendingDisable = nil } }), presenting: pendingDisable) { target in
            Button(L10n.text("Keep Enabled"), role: .cancel) { pendingDisable = nil }
            Button(L10n.text("Turn Off"), role: .destructive) {
                env.taste.change { if target == .analysis { $0.enabled = false } else { $0.aiEnabled = false } }
                pendingDisable = nil
            }
        } message: { target in
            Text(L10n.text(target == .analysis ? "New taste evidence, recommendations and reports will pause. Existing analysis and saved works are kept. Your other devices apply this choice after syncing." : "New AI explanations will pause. Your statistics and recommendations will continue to work without AI."))
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
