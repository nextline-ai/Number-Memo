import SwiftUI
import UniformTypeIdentifiers

struct AnimeBoxesImportView: View {
    @Environment(BooruStore.self) private var store
    @State private var picking = false
    @State private var backup: AnimeBoxesBackup?
    @State private var options = AnimeBoxesImportOptions()
    @State private var loading = false
    @State private var result: AnimeBoxesImportResult?
    @State private var error: String?
    @State private var readTask: Task<Void, Never>?
    var body: some View {
        Form {
            Section {
                Label(L10n.text("Import from Anime Boxes"), systemImage: "shippingbox.fill").font(.headline)
                Text(L10n.text("Export a backup in Anime Boxes, then choose the .abbj file here. Review its contents before importing."))
                    .font(.subheadline).foregroundStyle(.secondary)
                Button(L10n.text(backup == nil ? "Choose Backup File" : "Choose Another File"), systemImage: "doc.badge.plus") { picking = true }
                    .accessibilityIdentifier("booru.import.choose").disabled(loading)
            }
            if loading { Section { ProgressView(L10n.text("Importing…")) } }
            if let error { Section { Text(error).foregroundStyle(.red).accessibilityIdentifier("booru.import.error") } }
            if let result {
                Section {
                    Label(L10n.text("Import Complete"), systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    Text(L10n.text("%@ favorites added · %@ duplicates preserved · %@ servers added", String(result.added), String(result.duplicates), String(result.serversAdded)))
                        .accessibilityIdentifier("booru.import.result")
                }
            } else if let backup {
                Section(L10n.text("Backup Contents")) {
                    LabeledContent(L10n.text("Servers"), value: String(backup.servers.count))
                    LabeledContent(L10n.text("Favorites"), value: String(backup.favorites.count))
                    LabeledContent(L10n.text("Search History"), value: String(backup.history.count))
                    LabeledContent(L10n.text("Tag Blacklist"), value: String(backup.blacklist.count))
                    DisclosureGroup(L10n.text("Servers")) {
                        ForEach(backup.servers) { server in
                            LabeledContent(server.displayName, value: server.engine.title)
                        }
                    }
                    let skipped = backup.skippedServers + backup.skippedFavorites + backup.skippedHistory + backup.skippedRules
                    if skipped > 0 {
                        Text(L10n.text("%@ unsupported or invalid entries will be skipped.", String(skipped))).foregroundStyle(.orange)
                    }
                }
                Section(L10n.text("Import Options")) {
                    Picker(L10n.text("Destination Folder"), selection: $options.folderID) {
                        Text(L10n.text("Site Folders")).tag("by-site")
                        if !store.folders().contains(where: { $0.id == "anime-boxes" }) { Text("Anime Boxes").tag("anime-boxes") }
                        ForEach(store.folders()) { Text($0.displayName).tag($0.id) }
                    }
                    Toggle(L10n.text("Import Search History"), isOn: $options.history)
                    Toggle(L10n.text("Import Tag Blacklist"), isOn: $options.blacklist)
                    Toggle(L10n.text("Use Server Selection from Backup"), isOn: $options.selection)
                }
                Section {
                    Button(L10n.text("Import"), systemImage: "square.and.arrow.down", action: commit)
                        .disabled(loading || backup.servers.isEmpty).accessibilityIdentifier("booru.import.confirm")
                } footer: {
                    Text(L10n.text("Existing favorites keep their folders. Shared search history and blacklist rules are copied to each imported server. API credentials and cookies must be set up again in server settings. Hitomi data is unchanged."))
                }
            }
        }
        .navigationTitle("Anime Boxes").navigationBarTitleDisplayMode(.inline)
        .fileImporter(isPresented: $picking, allowedContentTypes: [.item]) { outcome in
            if case .success(let url) = outcome { read(url) }
            else if case .failure(let failure) = outcome { error = failure.localizedDescription }
        }
        .onDisappear { readTask?.cancel() }
        #if DEBUG
        .task {
            if ProcessInfo.processInfo.arguments.contains("--booru-import-test") {
                do { backup = try AnimeBoxesBackup.parse(BooruUITestSupport.importFixture) } catch { self.error = error.localizedDescription }
            }
        }
        #endif
    }
    private func read(_ url: URL) {
        readTask?.cancel(); loading = true; result = nil; error = nil; backup = nil
        readTask = Task {
            do {
                let parsed = try await Task.detached(priority: .userInitiated) { try AnimeBoxesBackup.read(url) }.value
                try Task.checkCancellation()
                backup = parsed; loading = false
            } catch { if !Task.isCancelled { self.error = error.localizedDescription; loading = false } }
        }
    }
    private func commit() {
        guard let backup else { return }
        loading = true; error = nil
        // Local SQLite transaction; no network work or media download is needed to import a library.
        Task { @MainActor in
            await Task.yield()
            do { result = try store.importAnimeBoxes(backup, options: options) }
            catch { self.error = error.localizedDescription }
            loading = false
        }
    }
}
