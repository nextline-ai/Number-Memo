import SwiftUI
import GRDB

public struct WorksGridView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    public let folder: Folder?
    public let artist: String?

    @State private var works: [Work] = []
    @State private var selecting = false
    @State private var selection = Set<Int64>()
    @State private var confirmingDelete = false
    @State private var allFolders: [Folder] = []
    @State private var searchText = ""
    @State private var showAddSheet = false
    @State private var selectedDetailGalleryId: Int64?
    @State private var activeBrowserUrl: String?
    @State private var workPendingDelete: Work?
    @State private var workPendingMoveToNewFolder: Work?
    @State private var showNewFolderAlert = false
    @State private var newFolderName = ""
    @State private var toastMessage: String?
    @State private var isSearchBarVisible = true
    @State private var searchScroll = ScrollSearchVisibility()
    @State private var showJumpSheet = false
    @State private var pendingJump: Int64?
    @FocusState private var isSearchFocused: Bool

    public init(folder: Folder? = nil, artist: String? = nil) {
        self.folder = folder
        self.artist = artist
    }

    private var canShowContent: Bool {
        #if DEBUG
        if ContentUITestSupport.libraryJumpTest { return true }
        #endif
        return env.isSiteVerified
    }

    private var isPushed: Bool {
        folder != nil || artist != nil
    }

    private var columns: [GridItem] {
        WorkGridLayout.columns(env.gridColumns, regular: horizontalSizeClass == .regular)
    }

    public var body: some View {
        ScrollViewReader { proxy in
        ZStack(alignment: .top) {
            ScrollView {
                VStack(spacing: 0) {
                    Color.clear.frame(height: 56).id("works.top")

                    if !canShowContent {
                        ContentUnavailableView(
                            L10n.text("Content Unavailable"),
                            systemImage: "lock.fill",
                            description: Text(L10n.text("Enter the correct service address in Settings."))
                        )
                        .padding(.top, 40)
                    } else if works.isEmpty {
                        ContentUnavailableView(
                            L10n.text("No Works"),
                            systemImage: "square.grid.2x2",
                            description: Text(searchText.isEmpty ? L10n.text("Add a work number to get started.") : L10n.text("No results for '%@'", String(describing: searchText)))
                        )
                        .padding(.top, 40)
                    } else {
                        LazyVGrid(columns: columns, spacing: 16) {
                            ForEach(works) { work in
                                WorkCardView(work: work)
                                    .id(work.galleryId)
                                    .accessibilityIdentifier("works.card.\(work.galleryId)")
                                    .contentShape(Rectangle())
                                    .onTapGesture {
                                        if selecting {
                                            if selection.contains(work.galleryId) { selection.remove(work.galleryId) } else { selection.insert(work.galleryId) }
                                        } else { openHitomi(for: work.galleryId) }
                                    }
                                    .overlay(alignment: .topTrailing) {
                                        if selecting { Image(systemName: selection.contains(work.galleryId) ? "checkmark.circle.fill" : "circle").font(.title2).foregroundStyle(.white, .blue).padding(10).allowsHitTesting(false) }
                                    }
                                    .contextMenu {
                                        workContextMenu(for: work)
                                    }
                            }
                        }
                        .padding(16)
                    }
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .trackScrollGeometry { oldY, newY in
                handleScrollGeometry(oldY: oldY, newY: newY)
            }

            standardSearchBar
                .offset(y: isSearchBarVisible ? 0 : -60)
                .opacity(isSearchBarVisible ? 1 : 0)
                .allowsHitTesting(isSearchBarVisible).accessibilityHidden(!isSearchBarVisible)
        }
        .animation(isSearchBarVisible ? .spring(response: 0.35, dampingFraction: 0.86) : .easeInOut(duration: 0.32), value: isSearchBarVisible)
        .onChange(of: searchText) { _, _ in
            loadWorks()
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(isPushed)
        .toolbarBackground(.hidden, for: .navigationBar)
        .sheet(item: Binding(
            get: { selectedDetailGalleryId.map { IdentifiableInt64(id: $0) } },
            set: { selectedDetailGalleryId = $0?.id }
        ), onDismiss: { loadWorks() }) { item in
            NavigationStack {
                WorkDetailView(galleryId: item.id)
            }
        }
        .fullScreenCover(item: Binding(
            get: { activeBrowserUrl.map { IdentifiableString(id: $0) } },
            set: { activeBrowserUrl = $0?.id }
        )) { item in
            ContentEntryView(initialUrl: item.id)
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                if isPushed {
                    Button {
                        dismiss()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "chevron.backward")
                                .font(.system(size: 14, weight: .bold))
                            Text(artist ?? folder?.displayName ?? L10n.text("All"))
                                .font(.system(size: 15, weight: .bold))
                        }
                        .foregroundColor(.primary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .fixedSize()
                    }
                    .buttonStyle(.plain)
                } else {
                    LiquidGlassTitleCapsule(L10n.text("All"))
                }
            }

            ToolbarItem(placement: .topBarTrailing) {
                HStack(spacing: 0) {
                    Button { selecting.toggle(); selection.removeAll() } label: { Image(systemName: selecting ? "xmark" : "checkmark.circle") }
                        .frame(width: 40, height: 32).accessibilityLabel(L10n.text(selecting ? "Done" : "Select")).accessibilityIdentifier("works.select")
                    if selecting {
                        Menu {
                            Button(L10n.text("Select All")) { selection = Set(works.map(\.galleryId)) }
                            ForEach(allFolders) { target in
                                Button(target.displayName) {
                                    do {
                                        if let id = target.id { try env.database.moveSelectedWorks(selection, to: id, from: folder?.id) }
                                        selection.removeAll(); selecting = false; loadWorks()
                                    } catch { showToast(error.localizedDescription) }
                                }
                            }
                        } label: { Image(systemName: "folder") }.frame(width: 40, height: 32).accessibilityLabel(L10n.text("Move to Another Folder"))
                        Button(role: .destructive) { confirmingDelete = true } label: { Image(systemName: "trash") }.frame(width: 40, height: 32).disabled(selection.isEmpty)
                    } else {
                    Menu {
                        Button(L10n.text("Jump to Top"), systemImage: "arrow.up.to.line") { isSearchFocused = false; proxy.scrollTo("works.top", anchor: .top) }
                        Button(L10n.text("Jump to Bottom"), systemImage: "arrow.down.to.line") {
                            isSearchFocused = false
                            if let id = works.last?.galleryId { proxy.scrollTo(id, anchor: .bottom) }
                        }
                        Button(L10n.text("Jump to Saved Month"), systemImage: "calendar") { isSearchFocused = false; showJumpSheet = true }
                    } label: { Image(systemName: "arrow.up.arrow.down") }
                    .frame(width: 40, height: 32)
                    .disabled(works.isEmpty).accessibilityLabel(L10n.text("Quick Jump")).accessibilityIdentifier("works.jump")
                    Button {
                        showAddSheet = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .frame(width: 40, height: 32)
                    .disabled(!env.isSiteVerified).accessibilityIdentifier("works.add")
                    }
                }
            }
        }
        .alert(L10n.text("Delete Selected Items?"), isPresented: $confirmingDelete) {
            Button(L10n.text("Delete"), role: .destructive) {
                do { try env.database.deleteSelectedWorks(selection); selection.removeAll(); selecting = false; loadWorks() }
                catch { showToast(error.localizedDescription) }
            }
            Button(L10n.text("Cancel"), role: .cancel) {}
        }
        .sheet(isPresented: $showJumpSheet, onDismiss: {
            if let id = pendingJump { proxy.scrollTo(id, anchor: .top); pendingJump = nil }
        }) {
            WorkMonthJumpView(months: WorkMonthDestination.make(works)) { id in
                pendingJump = id; showJumpSheet = false
            }
        }
        .sheet(isPresented: $showAddSheet, onDismiss: { loadWorks() }) {
            AddWorkSheet()
        }
        .alert(L10n.text("Delete Work"), isPresented: Binding(
            get: { workPendingDelete != nil },
            set: { if !$0 { workPendingDelete = nil } }
        )) {
            Button(L10n.text("Delete"), role: .destructive) {
                if let work = workPendingDelete {
                    deleteWork(work.galleryId)
                    workPendingDelete = nil
                }
            }
            Button(L10n.text("Cancel"), role: .cancel) {
                workPendingDelete = nil
            }
        } message: {
            if let work = workPendingDelete {
                Text(L10n.text("Delete this work (number: %@)?", String(describing: String(work.galleryId))))
            }
        }
        .alert(L10n.text("Create Folder and Move"), isPresented: $showNewFolderAlert) {
            TextField(L10n.text("New Folder Name"), text: $newFolderName)
            Button(L10n.text("Cancel"), role: .cancel) {
                newFolderName = ""
                workPendingMoveToNewFolder = nil
            }
            Button(L10n.text("Create and Move")) {
                if let work = workPendingMoveToNewFolder {
                    let trimmed = newFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty, let newFolder = try? env.database.createFolder(name: trimmed) {
                        moveWork(work, to: newFolder)
                    }
                }
                newFolderName = ""
                workPendingMoveToNewFolder = nil
            }
            .disabled(newFolderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .overlay(alignment: .bottom) {
            if let toastMessage {
                Text(toastMessage)
                    .font(.subheadline.bold())
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.ultraThinMaterial, in: Capsule())
                    .shadow(radius: 6)
                    .padding(.bottom, 24)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .background {
            #if os(iOS)
            NavigationPopGestureEnabler().frame(width: 0, height: 0)
            #endif
        }
        .task {
            do {
                let observation = ValueObservation.tracking { db in
                    try [Row.fetchAll(db, sql: "SELECT * FROM works"), Row.fetchAll(db, sql: "SELECT * FROM folders"), Row.fetchAll(db, sql: "SELECT * FROM folder_works"), Row.fetchAll(db, sql: "SELECT * FROM artists")]
                }
                for try await _ in observation.values(in: env.database.dbWriter) { loadWorks() }
            } catch { loadWorks() }
        }
        }
    }

    private func openHitomi(for galleryId: Int64) {
        guard canShowContent else { return }
        let urlString = "https://hitomi.la/reader/\(galleryId).html#1"
        activeBrowserUrl = urlString
    }

    private func loadWorks() {
        do {
            self.works = try env.database.listWorks(
                folderId: folder?.id,
                query: searchText.isEmpty ? nil : searchText,
                artist: artist
            )
            self.allFolders = (try? env.database.listFolders()) ?? []
        } catch {
            self.works = []
        }
    }

    private func moveWork(_ work: Work, to targetFolder: Folder) {
        guard let targetId = targetFolder.id else { return }
        do {
            try env.database.moveWorkToFolder(
                galleryId: work.galleryId,
                targetFolderId: targetId,
                currentFolderId: folder?.id
            )
            loadWorks()
            showToast(L10n.text("Moved to folder '%@'", String(describing: targetFolder.displayName)))
        } catch {
            print("Failed to move work: \(error)")
        }
    }

    private func showToast(_ message: String) {
        toastMessage = message
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            if toastMessage == message {
                toastMessage = nil
            }
        }
    }

    private func deleteWork(_ galleryId: Int64) {
        try? env.database.deleteWork(galleryId: galleryId)
        loadWorks()
    }

    @ViewBuilder
    private func workContextMenu(for work: Work) -> some View {
        Menu {
            Button {
                workPendingMoveToNewFolder = work
                newFolderName = ""
                showNewFolderAlert = true
            } label: {
                Label(L10n.text("Create New Folder…"), systemImage: "folder.badge.plus")
            }

            Divider()

            ForEach(allFolders) { targetFolder in
                Button {
                    moveWork(work, to: targetFolder)
                } label: {
                    HStack {
                        Text(targetFolder.displayName)
                        if targetFolder.id == folder?.id {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            Label(L10n.text("Move to Another Folder"), systemImage: "folder")
        }

        Button {
            selectedDetailGalleryId = work.galleryId
        } label: {
            Label(L10n.text("More Settings"), systemImage: "info.circle")
        }

        Button {
            UIPasteboard.general.string = String(work.galleryId)
            showToast(L10n.text("Copied work number %@", String(describing: String(work.galleryId))))
        } label: {
            Label(L10n.text("Copy Work Number (%@)", String(describing: String(work.galleryId))), systemImage: "doc.on.doc")
        }

        Button(role: .destructive) {
            workPendingDelete = work
        } label: {
            Label(L10n.text("Delete"), systemImage: "trash")
        }
    }

    private var standardSearchBar: some View {
        ScrollSearchBar(text: $searchText, focused: $isSearchFocused, prompt: L10n.text("Search works"), identifier: "works.search")
    }

    private func handleScrollGeometry(oldY: CGFloat, newY: CGFloat) {
        if let visible = searchScroll.update(oldY: oldY, newY: newY, focused: isSearchFocused) {
            isSearchBarVisible = visible
        }
    }

}

extension View {
    @ViewBuilder
    func trackScrollGeometry(onScroll: @escaping (CGFloat, CGFloat) -> Void) -> some View {
        if #available(iOS 18.0, *) {
            self.onScrollGeometryChange(for: CGFloat.self) { geo in
                geo.contentOffset.y
            } action: { oldY, newY in
                onScroll(oldY, newY)
            }
        } else {
            self
        }
    }
}

#if os(iOS)
private final class PopGestureController: UIViewController, UIGestureRecognizerDelegate {
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        navigationController?.interactivePopGestureRecognizer?.delegate = self
        navigationController?.interactivePopGestureRecognizer?.isEnabled = true
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        return (navigationController?.viewControllers.count ?? 0) > 1
    }
}

private struct NavigationPopGestureEnabler: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> PopGestureController {
        PopGestureController()
    }
    func updateUIViewController(_ uiViewController: PopGestureController, context: Context) {}
}
#endif






/// Accumulate movement so slow drags and 120 Hz displays behave like fast swipes.
/// This is intentionally not observable: only a visibility change redraws the view.
final class ScrollSearchVisibility {
    private var travel: CGFloat = 0
    func update(oldY: CGFloat, newY: CGFloat, focused: Bool) -> Bool? {
        if focused || newY <= 15 { travel = 0; return true }
        let delta = newY - oldY
        guard abs(delta) > 0.1 else { return nil }
        if travel * delta < 0 { travel = delta } else { travel += delta }
        if travel >= 32 { travel = 0; return false }
        if travel <= -24 { travel = 0; return true }
        return nil
    }
}

/// Shared by library and Explore so scrolling and search appearance stay consistent.
struct ScrollSearchBar: View {
    @Binding var text: String
    var focused: FocusState<Bool>.Binding
    let prompt: String
    let identifier: String
    var submit: () -> Void = {}
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").font(.system(size: 16, weight: .medium)).foregroundStyle(.secondary)
            TextField(prompt, text: $text)
                .font(.system(size: 16)).textFieldStyle(.plain)
                .autocorrectionDisabled().textInputAutocapitalization(.never)
                .focused(focused).submitLabel(.search).onSubmit(submit)
                .accessibilityIdentifier(identifier)
            Button {
                if text.isEmpty { focused.wrappedValue = false } else { text = "" }
            } label: { Image(systemName: "xmark.circle.fill").font(.system(size: 17)).foregroundStyle(.secondary) }
                .buttonStyle(.plain).opacity((focused.wrappedValue || !text.isEmpty) ? 1 : 0)
                .accessibilityLabel(L10n.text("Clear Search"))
        }
        .padding(.horizontal, 14).frame(height: 44).glassCapsule(isInteractive: true)
        .padding(.horizontal, 16).padding(.vertical, 6)
    }
}

struct WorkMonthDestination: Identifiable {
    let id: String
    let firstGalleryID: Int64
    var count: Int
    var title: String {
        let parts = id.split(separator: "-")
        guard parts.count == 2, let month = Int(parts[1]) else { return L10n.text("No Date") }
        return L10n.text("%@-%@", String(describing: parts[0]), String(describing: month))
    }
    static func make(_ works: [Work]) -> [Self] {
        var destinations: [Self] = []
        var positions: [String: Int] = [:]
        for work in works {
            let month = String(work.bookmarkedAt.prefix(7))
            if let index = positions[month] { destinations[index].count += 1 }
            else {
                positions[month] = destinations.count
                destinations.append(Self(id: month, firstGalleryID: work.galleryId, count: 1))
            }
        }
        return destinations
    }
}

private struct WorkMonthJumpView: View {
    @Environment(\.dismiss) private var dismiss
    let months: [WorkMonthDestination]
    let select: (Int64) -> Void
    var body: some View {
        NavigationStack {
            List(months) { month in
                Button { select(month.firstGalleryID) } label: {
                    HStack {
                        Text(month.title).foregroundStyle(.primary)
                        Spacer()
                        Text(L10n.text("%@ items", String(describing: month.count))).foregroundStyle(.secondary)
                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                    }
                }.accessibilityIdentifier("works.month.\(month.id)")
            }
            .navigationTitle(L10n.text("Jump to Saved Month")).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(L10n.text("Close")) { dismiss() } } }
        }.presentationDetents([.medium, .large])
    }
}
