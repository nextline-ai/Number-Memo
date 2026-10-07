import SwiftUI

struct BooruFavoritesView: View {
    let source: any BooruProviding
    @Environment(AppEnvironment.self) private var env
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(BooruStore.self) private var store
    @State private var creating = false
    @State private var newFolderName = ""
    @State private var editing: BooruFolderEdit?
    @State private var deleting: BooruFolder?
    @State private var reordering = false
    @State private var renaming: BooruFolder?
    @State private var showRename = false
    @State private var renameDraft = ""
    private var posts: [BooruPost] { store.visibleFavorites() }
    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                NavigationLink { BooruFolderContentsView(source: source) } label: {
                    HStack(spacing: 14) {
                        Image(systemName: "square.grid.2x2.fill").font(.title2).foregroundStyle(.tint)
                        Text(L10n.text("All Favorites")).font(.headline).foregroundStyle(.primary)
                        Spacer()
                        Text(String(posts.count)).foregroundStyle(.secondary)
                        Image(systemName: "chevron.right").font(.caption.bold()).foregroundStyle(.secondary)
                    }.padding(18).background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))
                }.accessibilityIdentifier("booru.allFavorites")
                LazyVGrid(columns: WorkGridLayout.columns(env.folderColumns, minimum: sizeClass == .regular ? 240 : 160), spacing: 14) {
                    ForEach(store.folders()) { folder in
                        NavigationLink { BooruFolderContentsView(source: source, folderID: folder.id) } label: {
                            BooruFolderCard(folder: folder, posts: store.visibleFavorites(folderID: folder.id))
                        }.buttonStyle(.plain).accessibilityIdentifier("booru.folder.\(folder.id)")
                            .contextMenu {
                                Button(L10n.text("Change Color"), systemImage: "paintpalette") { editing = .init(folder: folder) }
                                Button(L10n.text("Reorder Folders"), systemImage: "arrow.up.arrow.down") { reordering = true }
                                if folder.id != "unsorted" {
                                    Button(L10n.text("Rename Folder"), systemImage: "pencil") { renaming = folder; renameDraft = folder.displayName; showRename = true }
                                    Button(L10n.text("Delete Folder"), systemImage: "trash", role: .destructive) { deleting = folder }
                                }
                            }
                    }
                }
            }.padding(16)
        }
        .toolbar { ToolbarItem(placement: .topBarTrailing) {
            HStack(spacing: 16) {
                Button { creating = true } label: { Image(systemName: "folder.badge.plus").font(.system(size: 17, weight: .medium)) }
                    .accessibilityLabel(L10n.text("Create Folder")).accessibilityIdentifier("booru.createFolder")
            }.padding(.horizontal, 8)
        } }
        .booruCreateFolderAlert(isPresented: $creating, name: $newFolderName)
        .sheet(isPresented: $reordering) { FolderOrderView(booru: true) }
        .sheet(item: $editing) { item in
            if let folder = item.folder {
                NativeColorPickerSheet(title: folder.displayName, color: folder.color, onColorSelected: { color in
                    store.perform { try store.setFolderColor(folder.id, color: NativeColorPickerSheet.argb(color)) }
                }, onDismiss: { editing = nil })
            }
        }
        .background {
            FolderNameAlert(isPresented: $showRename, name: $renameDraft, identifier: "folder.rename", title: "Rename Folder", actionTitle: "Save") { value in
                if let folder = renaming { store.perform { try store.saveFolder(id: folder.id, name: value, color: folder.color) } }
            }
        }
        .confirmationDialog(L10n.text("Delete Folder?"), isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
            Button(L10n.text("Delete"), role: .destructive) { if let deleting { store.perform { try store.deleteFolder(deleting.id) } }; deleting = nil }
        } message: { Text(L10n.text("Favorites in this folder will move to Uncategorized.")) }
    }
}

private struct BooruFolderCard: View {
    let folder: BooruFolder
    let posts: [BooruPost]
    @Environment(BooruStore.self) private var store
    var body: some View {
        VStack(spacing: 0) {
            Color.clear.aspectRatio(1.25, contentMode: .fit).overlay {
                VStack(spacing: 4) {
                    ForEach(0..<2) { row in
                        HStack(spacing: 4) {
                            ForEach(0..<2) { col in
                                let index = row * 2 + col
                                Color.white.opacity(0.12).overlay {
                                    if posts.indices.contains(index), let server = store.servers.first(where: { $0.id == posts[index].serverID }) {
                                        BooruThumbnail(post: posts[index], server: server)
                                    } else { Image(systemName: "photo").font(.title3).foregroundStyle(.white.opacity(0.3)) }
                                }.clipped().clipShape(RoundedRectangle(cornerRadius: 8))
                            }
                        }
                    }
                }.padding(6)
            }.clipped()
            VStack(alignment: .leading, spacing: 3) {
                Text(folder.displayName).font(.subheadline.bold()).lineLimit(1)
                Text(L10n.text("%@ items", String(posts.count))).font(.caption2.weight(.semibold)).opacity(0.85)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 10).padding(.vertical, 8)
        }.foregroundStyle(.white).background(Color(argb: folder.color))
            .clipShape(RoundedRectangle(cornerRadius: 16)).overlay(RoundedRectangle(cornerRadius: 16).stroke(.white.opacity(0.15), lineWidth: 0.5))
    }
}

struct BooruFolderContentsView: View {
    let source: any BooruProviding
    var folderID: String?
    @Environment(BooruStore.self) private var store
    @State private var query = ""
    @State private var selectedPost: BooruPost?
    @State private var selecting = false
    @State private var selection = Set<String>()
    @State private var confirmingDelete = false
    @State private var showJump = false
    @State private var pendingJump: String?
    @State private var isSearchBarVisible = true
    @State private var searchScroll = ScrollSearchVisibility()
    @FocusState private var searchFocused: Bool
    private var posts: [BooruPost] { store.visibleFavorites(folderID: folderID, query: query) }
    var body: some View {
        ScrollViewReader { proxy in
        ZStack(alignment: .top) {
            ScrollView {
                Group {
                    if posts.isEmpty {
                        ContentUnavailableView(L10n.text("No Favorites"), systemImage: "heart", description: Text(L10n.text("Hold an image to save it, or choose Save to Folder from its menu."))).padding(.top, 48)
                    } else { BooruPostGrid(posts: posts, selection: selecting ? $selection : nil) { selectedPost = $0 }.padding(16) }
                }.padding(.top, 56)
            }
            .scrollDismissesKeyboard(.interactively)
            .trackScrollGeometry { oldY, newY in
                if let visible = searchScroll.update(oldY: oldY, newY: newY, focused: searchFocused) { isSearchBarVisible = visible }
            }
            ScrollSearchBar(text: $query, focused: $searchFocused, prompt: L10n.text("Search Favorites"), identifier: "booru.favoritesSearch")
                .offset(y: isSearchBarVisible ? 0 : -60).opacity(isSearchBarVisible ? 1 : 0)
                .allowsHitTesting(isSearchBarVisible).accessibilityHidden(!isSearchBarVisible)
        }
        .animation(isSearchBarVisible ? .spring(response: 0.35, dampingFraction: 0.86) : .easeInOut(duration: 0.32), value: isSearchBarVisible)
        .onChange(of: searchFocused) { _, focused in if focused { isSearchBarVisible = true } }
        .navigationTitle(store.folders().first(where: { $0.id == folderID })?.displayName ?? L10n.text("All Favorites"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .topBarTrailing) {
            HStack(spacing: 16) {
                if selecting {
                    Button { selection = Set(posts.map(\.id)) } label: { Image(systemName: "checkmark.circle.fill") }.accessibilityLabel(L10n.text("Select All"))
                    Menu {
                        ForEach(store.folders()) { folder in
                            Button(folder.displayName) { store.perform { try store.moveFavorites(posts.filter { selection.contains($0.id) }, folderID: folder.id); selection.removeAll(); selecting = false } }
                        }
                    } label: { Image(systemName: "folder") }.disabled(selection.isEmpty).accessibilityLabel(L10n.text("Move to Another Folder"))
                    Button(role: .destructive) { confirmingDelete = true } label: { Image(systemName: "trash") }.disabled(selection.isEmpty).accessibilityLabel(L10n.text("Delete")).accessibilityIdentifier("booru.deleteSelected")
                } else {
                    Menu {
                        Button(L10n.text("Jump to Top"), systemImage: "arrow.up.to.line") { if let first = posts.first { proxy.scrollTo(first.id, anchor: .top) } }
                        Button(L10n.text("Jump to Bottom"), systemImage: "arrow.down.to.line") { if let last = posts.last { proxy.scrollTo(last.id, anchor: .bottom) } }
                        Button(L10n.text("Jump to Saved Month"), systemImage: "calendar") { showJump = true }
                    } label: { Image(systemName: "arrow.up.arrow.down") }.accessibilityLabel(L10n.text("Quick Jump"))
                }
                Button { selecting.toggle(); selection.removeAll() } label: { Image(systemName: selecting ? "xmark" : "checkmark.circle") }
                    .accessibilityLabel(L10n.text(selecting ? "Done" : "Select")).accessibilityIdentifier("booru.select")
            }
        } }
        .alert(L10n.text("Delete Selected Items?"), isPresented: $confirmingDelete) {
            Button(L10n.text("Delete"), role: .destructive) { store.perform { try store.removeFavorites(posts.filter { selection.contains($0.id) }); selection.removeAll(); selecting = false } }
            Button(L10n.text("Cancel"), role: .cancel) {}
        }
        .sheet(isPresented: $showJump, onDismiss: { if let pendingJump { proxy.scrollTo(pendingJump, anchor: .top); self.pendingJump = nil } }) {
            NavigationStack {
                List(months, id: \.month) { item in
                    Button(item.month) { pendingJump = item.id; showJump = false }
                }.navigationTitle(L10n.text("Jump to Saved Month"))
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button(L10n.text("Close")) { showJump = false } } }
            }.presentationDetents([.medium, .large])
        }
        .fullScreenCover(item: $selectedPost) { post in
            if let server = store.servers.first(where: { $0.id == post.serverID }) { BooruPostView(post: post, posts: posts, server: server, source: source) }
        }
        }
    }
    private var months: [(month: String, id: String)] {
        let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM"
        var seen = Set<String>()
        return posts.compactMap { post in
            let month = store.savedDate(for: post).map(formatter.string(from:)) ?? L10n.text("No Date")
            return seen.insert(month).inserted ? (month, post.id) : nil
        }
    }
}

private struct BooruFolderEdit: Identifiable {
    let id = UUID()
    var folder: BooruFolder?
}

struct BooruFolderPicker: View {
    @Environment(\.discoveryContext) private var discovery
    let post: BooruPost
    @Environment(BooruStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var creating = false
    @State private var newFolderName = ""
    @State private var error: String?
    var body: some View {
        NavigationStack {
            List {
                ForEach(store.folders()) { folder in
                    Button {
                        do { try store.saveFavorite(post, folderID: folder.id, context: discovery); dismiss() }
                        catch { self.error = error.localizedDescription }
                    } label: {
                        HStack {
                            Image(systemName: "folder.fill").foregroundStyle(Color(argb: folder.color))
                            Text(folder.displayName).foregroundStyle(.primary)
                            Spacer()
                            if store.folderID(for: post) == folder.id { Image(systemName: "checkmark").foregroundStyle(.tint) }
                        }
                    }.accessibilityIdentifier("booru.pickFolder.\(folder.id)")
                }
                Button(L10n.text("Create Folder"), systemImage: "folder.badge.plus") { creating = true }
                if let error { Text(error).foregroundStyle(.red) }
            }.navigationTitle(L10n.text("Save to Folder")).navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button(L10n.text("Cancel")) { dismiss() } } }
                .booruCreateFolderAlert(isPresented: $creating, name: $newFolderName)
        }.presentationDetents([.medium, .large])
    }
}

private struct BooruCreateFolderModifier: ViewModifier {
    @Environment(BooruStore.self) private var store
    @Binding var isPresented: Bool
    @Binding var name: String
    func body(content: Content) -> some View {
        content.background {
            FolderNameAlert(isPresented: $isPresented, name: $name, identifier: "booru.folderName") { folderName in
                store.perform { try store.saveFolder(name: folderName) }
            }.frame(width: 0, height: 0)
        }
    }
}

private extension View {
    func booruCreateFolderAlert(isPresented: Binding<Bool>, name: Binding<String>) -> some View {
        modifier(BooruCreateFolderModifier(isPresented: isPresented, name: name))
    }
}

extension BooruStore {
    func visibleFavorites(folderID: String? = nil, query: String = "") -> [BooruPost] {
        let filters = Dictionary(uniqueKeysWithValues: servers.map { ($0.id, BooruBlacklist(blacklist(serverID: $0.id))) })
        return favorites(serverIDs: servers.map(\.id), folderID: folderID).filter {
            !(filters[$0.serverID]?.contains($0) ?? false) && (query.isEmpty || $0.tags.joined(separator: " ").localizedCaseInsensitiveContains(query) || String($0.postID).contains(query))
        }
    }
}
