import SwiftUI

struct FolderOrderView: View {
    let booru: Bool
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    @State private var entries: [Entry] = []
    @State private var error: String?
    private struct Entry: Identifiable { let id: String; let name: String }
    var body: some View {
        NavigationStack {
            List {
                ForEach(entries) { Text($0.name) }
                    .onMove { from, to in entries.move(fromOffsets: from, toOffset: to) }
                if let error { Text(error).foregroundStyle(.red) }
            }.environment(\.editMode, .constant(.active))
                .navigationTitle(L10n.text("Reorder Folders")).navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button(L10n.text("Cancel")) { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) { Button(L10n.text("Save")) {
                        do {
                            if booru { try env.booru.reorderFolders(entries.map(\.id)) }
                            else { try env.database.reorderFolders(entries.compactMap { Int64($0.id) }) }
                            dismiss()
                        } catch { self.error = error.localizedDescription }
                    } }
                }
                .onAppear {
                    if booru { entries = env.booru.folders().map { Entry(id: $0.id, name: $0.displayName) } }
                    else { entries = ((try? env.database.listFolders()) ?? []).compactMap { folder in folder.id.map { Entry(id: String($0), name: folder.displayName) } } }
                }
        }
    }
}
