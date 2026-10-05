import SwiftUI
import UniformTypeIdentifiers

struct BooruBackupView: View {
    @Environment(BooruStore.self) private var store
    @State private var picking = false
    @State private var pending: BooruBackup?
    @State private var sharing: BackupFile?
    @State private var busy = false
    @State private var message: String?

    var body: some View {
        Form {
            Section {
                Button(L10n.text("Export JSON Backup"), systemImage: "square.and.arrow.up") { export() }
                    .accessibilityIdentifier("booru.backupExport")
                Button(L10n.text("Import / Restore JSON Backup"), systemImage: "square.and.arrow.down") { picking = true }
                    .accessibilityIdentifier("booru.backupImport")
            } header: { Text(L10n.text("Backup & Restore")) } footer: {
                Text(L10n.text("Back up servers, favorites, folder colors and order, saved tags, searches and blacklists. Images and sign-in details are not included."))
            }
            Section {
                NavigationLink { AnimeBoxesImportView() } label: { Label(L10n.text("Import from Anime Boxes"), systemImage: "shippingbox") }
                    .accessibilityIdentifier("booru.importLink")
            }
            if busy { ProgressView(L10n.text("Restoring backup…")) }
            if let message { Section { Text(message).font(.footnote) } }
        }
        .disabled(busy)
        .navigationTitle(L10n.text("Library Management"))
        .navigationBarTitleDisplayMode(.inline)
        .fileImporter(isPresented: $picking, allowedContentTypes: [.json], allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls): if let url = urls.first { load(url) }
            case .failure(let error): message = error.localizedDescription
            }
        }
        .sheet(item: $sharing) { file in BooruBackupShareSheet(url: file.url) }
        .alert(L10n.text("Restore Image Library?"), isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } })) {
            Button(L10n.text("Cancel"), role: .cancel) { pending = nil }
            Button(L10n.text("Restore")) { if let backup = pending { pending = nil; restore(backup) } }
        } message: {
            Text(L10n.text("The backup will be merged with your library. Matching favorites, folder colors and order will use the backup values. These changes also sync when iCloud is enabled."))
        }
    }

    private func export() {
        busy = true
        Task {
            do {
                let store = store
                let url = try await Task.detached(priority: .userInitiated) {
                    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    let url = directory.appendingPathComponent("number-memo-images-backup.json")
                    try store.exportBackup().encoded().write(to: url, options: .atomic)
                    return url
                }.value
                sharing = BackupFile(url: url)
            } catch { message = L10n.text("Unable to create backup: %@", error.localizedDescription) }
            busy = false
        }
    }

    private func load(_ url: URL) {
        busy = true
        Task {
            do { pending = try await Task.detached(priority: .userInitiated) { try BooruBackup.read(url) }.value }
            catch { message = L10n.text("Unable to restore backup: %@", error.localizedDescription) }
            busy = false
        }
    }

    private func restore(_ backup: BooruBackup) {
        // Restore on the main actor so observable library changes reach the UI together.
        do {
            try store.restoreBackup(backup)
            message = L10n.text("Backup restored: %@ works, %@ folders", String(backup.favorites.count), String(backup.folders.count))
        } catch { message = L10n.text("Unable to restore backup: %@", error.localizedDescription) }
    }
}

private struct BackupFile: Identifiable { let id = UUID(); let url: URL }
private struct BooruBackupShareSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: [url], applicationActivities: nil) }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
