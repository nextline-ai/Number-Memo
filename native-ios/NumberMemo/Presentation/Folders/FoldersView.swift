import SwiftUI
import GRDB

public struct FoldersView: View {
    @Environment(AppEnvironment.self) private var env

    @State private var folders: [Folder] = []
    @State private var previews: [Int64: [Work]] = [:]
    @State private var showCreateAlert = false
    @State private var newFolderName = ""
    @State private var showAddSheet = false
    @State private var editingColorFolder: Folder?
    @State private var folderPendingDelete: Folder?
    @State private var renamingFolder: Folder?
    @State private var showRename = false
    @State private var renameDraft = ""
    @State private var editError: String?
    @State private var reordering = false

    private let columns = [
        GridItem(.flexible(), spacing: 14),
        GridItem(.flexible(), spacing: 14)
    ]

    public init() {}

    public var body: some View {
        ScrollView {
            if !env.isSiteVerified {
                ContentUnavailableView(
                    L10n.text("Content Unavailable"),
                    systemImage: "lock.fill",
                    description: Text(L10n.text("Enter the correct service address in Settings."))
                )
                .padding(.top, 60)
            } else if folders.isEmpty {
                ContentUnavailableView(
                    L10n.text("No Folders"),
                    systemImage: "folder",
                    description: Text(L10n.text("Create a folder to organize your works."))
                )
                .padding(.top, 60)
            } else {
                LazyVGrid(columns: columns, spacing: 14) {
                    ForEach(folders) { folder in
                        NavigationLink(value: folder) {
                            FolderBentoCardView(
                                folder: folder,
                                previews: folder.id.flatMap { previews[$0] } ?? []
                            )
                            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                            .contextMenu {
                                Button {
                                    editingColorFolder = folder
                                } label: {
                                    Label(L10n.text("Change Color"), systemImage: "paintpalette")
                                }

                                Button(L10n.text("Reorder Folders"), systemImage: "arrow.up.arrow.down") { reordering = true }
                                if folder.name != "미분류" {
                                    Button(L10n.text("Rename Folder"), systemImage: "pencil") {
                                        renamingFolder = folder; renameDraft = folder.name; showRename = true
                                    }
                                    Button(role: .destructive) {
                                        folderPendingDelete = folder
                                    } label: {
                                        Label(L10n.text("Delete Folder"), systemImage: "trash")
                                    }
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(16)
            }
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .navigationDestination(for: Folder.self) { folder in
            WorksGridView(folder: folder)
        }
        .toolbar {
            ToolbarItem(placement: .principal) { AppModeSwitch() }
            ToolbarItem(placement: .topBarLeading) {
                LiquidGlassTitleCapsule(L10n.text("Saved"))
            }

            ToolbarItem(placement: .topBarTrailing) {
                HStack(spacing: 16) {
                    Button {
                        showCreateAlert = true
                    } label: {
                        Image(systemName: "folder.badge.plus")
                            .font(.system(size: 17, weight: .medium))
                    }
                    .disabled(!env.isSiteVerified)
                    .accessibilityLabel(L10n.text("Create Folder"))
                    .accessibilityIdentifier("hitomi.createFolder")

                    Button {
                        showAddSheet = true
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 18, weight: .medium))
                    }
                    .disabled(!env.isSiteVerified)
                }
                .padding(.horizontal, 8)
            }
        }
        .background {
            FolderNameAlert(isPresented: $showCreateAlert, name: $newFolderName) { name in
                newFolderName = name
                createFolder()
            }.frame(width: 0, height: 0)
        }
        .alert(
            L10n.text("Delete the folder '%@'?", String(describing: folderPendingDelete?.name ?? "")),
            isPresented: Binding(
                get: { folderPendingDelete != nil },
                set: { if !$0 { folderPendingDelete = nil } }
            ),
            presenting: folderPendingDelete
        ) { folder in
            Button(L10n.text("Delete"), role: .destructive) {
                if let id = folder.id {
                    deleteFolder(id)
                }
                folderPendingDelete = nil
            }
            Button(L10n.text("Cancel"), role: .cancel) {
                folderPendingDelete = nil
            }
        } message: { _ in
            Text(L10n.text("Works in this folder will be moved to Unfiled."))
        }
        .sheet(isPresented: $showAddSheet, onDismiss: { loadFolders() }) {
            AddWorkSheet()
        }
        .sheet(isPresented: $reordering, onDismiss: loadFolders) { FolderOrderView(booru: false) }
        .sheet(item: $editingColorFolder) { folder in
            NativeColorPickerSheet(
                title: folder.displayName, color: folder.color,
                onColorSelected: { newColor in
                    if let id = folder.id {
                        saveColor(folderId: id, color: newColor)
                    }
                },
                onDismiss: {
                    editingColorFolder = nil
                }
            )
        }
        .background {
            FolderNameAlert(isPresented: $showRename, name: $renameDraft, identifier: "folder.rename", title: "Rename Folder", actionTitle: "Save") { value in
                do { if let id = renamingFolder?.id { try env.database.renameFolder(id: id, name: value) }; loadFolders() }
                catch { editError = error.localizedDescription }
            }
        }
        .alert(L10n.text("Error"), isPresented: Binding(get: { editError != nil }, set: { if !$0 { editError = nil } })) {
            Button(L10n.text("OK"), role: .cancel) { editError = nil }
        } message: { Text(editError ?? "") }
        .task {
            do {
                let observation = ValueObservation.tracking { db in
                    try [Row.fetchAll(db, sql: "SELECT * FROM works"), Row.fetchAll(db, sql: "SELECT * FROM folders"), Row.fetchAll(db, sql: "SELECT * FROM folder_works"), Row.fetchAll(db, sql: "SELECT * FROM artists")]
                }
                for try await _ in observation.values(in: env.database.dbWriter) { loadFolders() }
            } catch { loadFolders() }
        }
    }

    private func loadFolders() {
        if let list = try? env.database.listFolders() {
            self.folders = list
        }
        if let p = try? env.database.folderPreviews(limitPerFolder: 4) {
            self.previews = p
        }
    }

    private func createFolder() {
        let trimmed = newFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        _ = try? env.database.createFolder(name: trimmed)
        newFolderName = ""
        loadFolders()
    }

    private func deleteFolder(_ id: Int64) {
        try? env.database.deleteFolder(id: id)
        loadFolders()
    }

    private func saveColor(folderId: Int64, color: Color) {
        try? env.database.setFolderColor(id: folderId, color: NativeColorPickerSheet.argb(color))
        loadFolders()
    }
}

struct NativeColorPickerSheet: UIViewControllerRepresentable {
    let title: String
    let color: Int64
    let onColorSelected: (Color) -> Void
    let onDismiss: () -> Void

    static func argb(_ color: Color) -> Int64 {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        UIColor(color).getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return 0xFF000000 | (Int64((red * 255).rounded()) << 16) | (Int64((green * 255).rounded()) << 8) | Int64((blue * 255).rounded())
    }

    func makeUIViewController(context: Context) -> UIColorPickerViewController {
        let picker = UIColorPickerViewController()
        picker.selectedColor = UIColor(Color(argb: color))
        picker.supportsAlpha = false
        picker.title = L10n.text("%@ color", title)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIColorPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject, UIColorPickerViewControllerDelegate {
        let parent: NativeColorPickerSheet

        init(_ parent: NativeColorPickerSheet) {
            self.parent = parent
        }

        func colorPickerViewController(_ viewController: UIColorPickerViewController, didSelect color: UIColor, continuously: Bool) {
            parent.onColorSelected(Color(uiColor: color))
        }

        func colorPickerViewControllerDidFinish(_ viewController: UIColorPickerViewController) {
            parent.onDismiss()
        }
    }
}

/// A shared modal prompt keeps the input inside equal horizontal margins.
/// Present above navigation chrome and sheets without changing system alert internals.
struct FolderNameAlert: UIViewControllerRepresentable {
    @Binding var isPresented: Bool
    @Binding var name: String
    var identifier = "folder.name"
    var title = "New Folder"
    var actionTitle = "Create"
    let onCreate: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIViewController(context: Context) -> Host {
        let host = Host()
        host.onAppear = { [weak host, weak coordinator = context.coordinator] in
            if let host { coordinator?.update(host) }
        }
        return host
    }
    func updateUIViewController(_ host: Host, context: Context) {
        context.coordinator.parent = self
        context.coordinator.update(host)
    }

    final class Host: UIViewController {
        var onAppear: (() -> Void)?
        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            onAppear?()
        }
    }

    final class Coordinator: NSObject {
        var parent: FolderNameAlert
        private weak var prompt: UIViewController?
        init(_ parent: FolderNameAlert) { self.parent = parent }

        func update(_ host: Host) {
            guard parent.isPresented else {
                if let prompt, !prompt.isBeingDismissed { prompt.dismiss(animated: true) }
                return
            }
            guard prompt == nil, host.view.window != nil, host.presentedViewController == nil else { return }
            let content = FolderNamePrompt(name: parent.$name, identifier: parent.identifier, title: parent.title, actionTitle: parent.actionTitle) { [weak self] name in
                guard let self else { return }
                self.parent.isPresented = false
                self.parent.name = ""
                if let name { self.parent.onCreate(name) }
            }
            let prompt = UIHostingController(rootView: content)
            prompt.modalPresentationStyle = .overFullScreen
            prompt.modalTransitionStyle = .crossDissolve
            prompt.view.backgroundColor = .clear
            prompt.view.accessibilityViewIsModal = true
            self.prompt = prompt
            host.present(prompt, animated: true)
        }
    }
}

private struct FolderNamePrompt: View {
    @Binding var name: String
    let identifier: String
    let title: String
    let actionTitle: String
    let finish: (String?) -> Void
    @FocusState private var focused: Bool
    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        ZStack {
            Color.black.opacity(0.3).ignoresSafeArea().accessibilityHidden(true)
            VStack(spacing: 20) {
                Text(L10n.text(title)).font(.headline)
                TextField(L10n.text("Folder Name"), text: $name)
                    .textFieldStyle(.plain)
                    .multilineTextAlignment(.leading)
                    .padding(.horizontal, 16).frame(minHeight: 48)
                    .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
                    .focused($focused).submitLabel(.done)
                    .onSubmit { if !trimmedName.isEmpty { finish(trimmedName) } }
                    .accessibilityIdentifier(identifier)
                HStack(spacing: 12) {
                    Button { finish(nil) } label: {
                        Text(L10n.text("Cancel")).frame(maxWidth: .infinity, minHeight: 44)
                    }.buttonStyle(.bordered).buttonBorderShape(.capsule)
                    Button { finish(trimmedName) } label: {
                        Text(L10n.text(actionTitle)).frame(maxWidth: .infinity, minHeight: 44)
                    }.buttonStyle(.borderedProminent).buttonBorderShape(.capsule).disabled(trimmedName.isEmpty)
                }
            }
            .padding(24).frame(maxWidth: 340)
            .glassSurface(cornerRadius: 32)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("folder.namePrompt")
            .padding(24)
        }
        .task { focused = true }
        .accessibilityAction(.escape) { finish(nil) }
    }
}
