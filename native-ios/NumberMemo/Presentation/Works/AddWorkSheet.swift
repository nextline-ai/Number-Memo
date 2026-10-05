import SwiftUI

public struct AddWorkSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppEnvironment.self) private var env

    public let initialText: String

    @State private var input: String
    @State private var folders: [Folder] = []
    @State private var selectedFolderId: Int64?
    @State private var isSaving = false
    @State private var detectedIds: [Int64] = []
    @State private var showCreateFolderAlert = false
    @State private var newFolderName = ""

    public init(initialText: String = "") {
        self.initialText = initialText
        _input = State(initialValue: initialText)
    }

    public var body: some View {
        NavigationStack {
            Form {
                Section(header: Text(L10n.text("Work Number or Link"))) {
                    TextEditor(text: $input)
                        .frame(minHeight: 100)
                        .onChange(of: input) { _, newValue in
                            detectedIds = GalleryIDParser.parse(newValue)
                        }

                    if input.isEmpty {
                        PasteButton(supportedContentTypes: [.text]) { providers in
                            _ = providers.first?.loadObject(ofClass: String.self) { string, _ in
                                if let string {
                                    Task { @MainActor in
                                        self.input = string
                                        self.detectedIds = GalleryIDParser.parse(string)
                                    }
                                }
                            }
                        }
                        .buttonBorderShape(.capsule)
                        .controlSize(.small)
                    }

                    if !detectedIds.isEmpty {
                        HStack {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                            Text(L10n.text("Found %@: %@", String(describing: detectedIds.count), String(describing: detectedIds.map { String($0) }.joined(separator: "  "))))
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    } else if !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        HStack {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.orange)
                            Text(L10n.text("No work numbers found"))
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }

                Section(header: Text(L10n.text("Save to Folder"))) {
                    Button {
                        newFolderName = ""
                        showCreateFolderAlert = true
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "folder.badge.plus")
                                .foregroundColor(.accentColor)
                            Text(L10n.text("Create New Folder…"))
                                .foregroundColor(.accentColor)
                        }
                    }

                    ForEach(folders) { folder in
                        Button {
                            selectedFolderId = folder.id
                        } label: {
                            HStack(spacing: 12) {
                                Circle()
                                    .fill(Color(argb: folder.color))
                                    .frame(width: 12, height: 12)

                                Text(folder.displayName)
                                    .foregroundColor(.primary)

                                Spacer()

                                if selectedFolderId == folder.id {
                                    Image(systemName: "checkmark")
                                        .foregroundColor(.accentColor)
                                        .font(.subheadline.bold())
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .navigationTitle(L10n.text("Add Work Number"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.text("Cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.text("Save")) {
                        save()
                    }
                    .disabled(detectedIds.isEmpty || isSaving)
                }
            }
            .alert(L10n.text("New Folder"), isPresented: $showCreateFolderAlert) {
                TextField(L10n.text("Folder Name"), text: $newFolderName)
                Button(L10n.text("Cancel"), role: .cancel) { newFolderName = "" }
                Button(L10n.text("Create")) {
                    createAndSelectFolder()
                }
                .disabled(newFolderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .task {
                loadFolders()
                if !input.isEmpty && detectedIds.isEmpty {
                    detectedIds = GalleryIDParser.parse(input)
                }
            }
        }
    }

    private func createAndSelectFolder() {
        let trimmed = newFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if let created = try? env.database.createFolder(name: trimmed) {
            loadFolders()
            selectedFolderId = created.id
        }
        newFolderName = ""
    }

    private func loadFolders() {
        if let list = try? env.database.listFolders() {
            folders = list
            if selectedFolderId == nil {
                selectedFolderId = list.first?.id
            }
        }
    }

    private func save() {
        guard !detectedIds.isEmpty else { return }
        isSaving = true

        Task {
            var createdCount = 0
            for id in detectedIds {
                let existing = try? env.database.getWork(galleryId: id)
                let catalog = try? env.database.getCatalog(galleryId: id)

                _ = try? env.database.upsertWork(
                    galleryId: id,
                    folderId: selectedFolderId,
                    title: catalog?.title,
                    artists: catalog?.artists,
                    language: catalog?.language,
                    type: catalog?.type,
                    series: catalog?.series,
                    groups: catalog?.groups,
                    tags: catalog?.tags,
                    publishedAt: catalog?.published,
                    metadataSource: catalog != nil ? "catalog" : nil,
                    catalogMatched: catalog != nil
                )
                if existing == nil {
                    createdCount += 1
                }
            }

            if createdCount > 0 {
                env.startCoverQueue()
            }

            await MainActor.run {
                isSaving = false
                dismiss()
            }
        }
    }
}
