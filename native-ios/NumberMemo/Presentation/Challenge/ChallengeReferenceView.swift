import SwiftUI

/// Shared filtering for live results and saved folders; random searches are not taste evidence.
enum ChallengeMediaFilter {
    static func matches(_ post: BooruPost, tags: [String], rating: BooruRating, blacklist: String, safeOnly: Bool) -> Bool {
        guard !BooruBlacklist(blacklist).contains(post) else { return false }
        let available = Set(post.tags.map { $0.lowercased() })
        guard tags.allSatisfy({ available.contains($0.lowercased()) }) else { return false }
        if rating == .all || safeOnly { return true }
        let wanted: String
        switch rating { case .general: wanted = "g"; case .sensitive: wanted = "s"; case .questionable: wanted = "q"; case .explicit: wanted = "e"; case .all: return true }
        let actual = ["general": "g", "safe": "g", "sensitive": "s", "questionable": "q", "explicit": "e"][post.rating] ?? post.rating
        return actual == wanted
    }
}

struct ChallengeReferenceView: View {
    let controller: ChallengeSessionController
    let source: any BooruProviding
    let header: AnyView
    @Environment(BooruStore.self) private var store
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var choosingSource = false
    private var servers: [BooruServer] {
        controller.session.sourceKind == "folder" ? store.servers : store.servers.filter { controller.session.serverIDs.contains($0.id) }
    }
    private var query: String { controller.session.mission?.tags.joined(separator: " ") ?? "" }
    private var feedID: String { (controller.session.mission?.id ?? "idle") + controller.session.sourceKind + controller.session.serverIDs.joined() + (controller.session.folderID ?? "") }
    private var feedSource: any BooruProviding {
        if controller.session.sourceKind == "folder", let folder = controller.session.folderID {
            return ChallengeFolderSource(store: store, folderID: folder, source: source)
        }
        return source
    }
    private var introduction: some View {
        VStack(spacing: 20) {
            header
            let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12)) : AnyLayout(HStackLayout())
            layout {
                Text(L10n.text("Reference Images")).font(.headline)
                if !typeSize.isAccessibilitySize { Spacer() }
                Button(L10n.text("Image Source"), systemImage: "slider.horizontal.3") { choosingSource = true }
                    .accessibilityIdentifier("challenge.source")
            }
            if controller.session.sourceKind == "folder" {
                Text(L10n.text("Saved images need a connection unless their media is already cached.")).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
    var body: some View {
        Group {
            if controller.session.canSearchImages && !servers.isEmpty && (controller.session.sourceKind != "folder" || controller.session.folderID != nil) {
                BooruFeedView(servers: servers, source: feedSource, initialQuery: query, challenge: controller, header: AnyView(introduction))
                    .id(feedID)
            } else {
                ScrollView {
                    VStack(spacing: 20) {
                        introduction
                        Text(L10n.text(controller.session.phase == .spinning ? "Images will load after the reels stop." : controller.session.mission == nil ? "Draw a mission to choose a reference image." : "Choose a registered server or a saved folder.")).foregroundStyle(.secondary)
                    }.padding(16)
                }
            }
        }.tint(.purple)
        .sheet(isPresented: $choosingSource) { ChallengeSourceView(controller: controller).tint(.purple) }
    }
}

/// Saved folders use the same search/grid/pagination UI without making list requests online.
struct ChallengeFolderSource: BooruProviding {
    let store: BooruStore
    let folderID: String
    let source: any BooruProviding
    func posts(server: BooruServer, query: String, page: Int) async throws -> BooruBatch {
        let terms = query.split(whereSeparator: \.isWhitespace).map(String.init)
        let ratingValue = terms.first { $0.hasPrefix("rating:") }.map { String($0.dropFirst(7)) }
        let rating = ratingValue == "safe" ? BooruRating.general : BooruRating(rawValue: ratingValue ?? "all") ?? .all
        let tags = terms.filter { !$0.hasPrefix("rating:") && !$0.hasPrefix("order:") && !$0.hasPrefix("sort:") }
        let popular = terms.contains("order:score") || terms.contains("sort:score:desc")
        let all = await MainActor.run {
            store.visibleFavorites(folderID: folderID).filter { post in
                let available = Set(post.tags.map { $0.lowercased() })
                let matches = tags.allSatisfy { term in
                    term.hasPrefix("-") ? !available.contains(String(term.dropFirst()).lowercased()) : available.contains(term.lowercased())
                }
                return matches && post.serverID == server.id && ChallengeMediaFilter.matches(post, tags: [], rating: rating, blacklist: store.blacklist(serverID: server.id), safeOnly: server.isSafeOnly)
            }
        }
        let ordered = popular ? all.sorted { $0.score == $1.score ? $0.postID > $1.postID : $0.score > $1.score } : all
        let start = max(0, page) * BooruClient.pageSize
        return .init(posts: Array(ordered.dropFirst(start).prefix(BooruClient.pageSize)), hasMore: start + BooruClient.pageSize < ordered.count)
    }
    func suggestions(server: BooruServer, token: String) async throws -> [BooruTag] {
        let tags = await MainActor.run { store.visibleFavorites(folderID: folderID).filter { $0.serverID == server.id }.flatMap(\.tags) }
        let counts = Dictionary(grouping: tags.filter { $0.hasPrefix(token) }, by: { $0 })
        return counts.map { BooruTag(name: $0.key, count: $0.value.count, category: 0) }.sorted { $0.count > $1.count }.prefix(12).map { $0 }
    }
    func details(server: BooruServer, post: BooruPost) async throws -> BooruPost { try await source.details(server: server, post: post) }
    func notes(server: BooruServer, postID: Int64) async throws -> [BooruNote] { try await source.notes(server: server, postID: postID) }
    func pools(server: BooruServer, query: String, page: Int) async throws -> [BooruPool] { [] }
    func poolPosts(server: BooruServer, poolID: Int64, page: Int) async throws -> BooruBatch { .init(posts: [], hasMore: false) }
}

private struct ChallengeSourceView: View {
    let controller: ChallengeSessionController
    @Environment(BooruStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var kind = "servers"
    @State private var serverIDs: [String] = []
    @State private var folderID: String?
    @State private var addingServer = false
    var body: some View {
        NavigationStack {
            Form {
                Picker(L10n.text("Image Source"), selection: $kind) {
                    Text(L10n.text("Servers")).tag("servers"); Text(L10n.text("Saved Folder")).tag("folder")
                }.pickerStyle(.segmented)
                if kind == "servers" {
                    ForEach(store.servers) { server in
                        Toggle(server.displayName, isOn: Binding(get: { serverIDs.contains(server.id) }, set: { checked in
                            serverIDs.removeAll { $0 == server.id }; if checked { serverIDs.append(server.id) }
                        }))
                    }
                    Button(L10n.text("Add a Server"), systemImage: "plus") { addingServer = true }
                } else {
                    Picker(L10n.text("Saved Folder"), selection: $folderID) {
                        Text(L10n.text("Choose a Folder")).tag(nil as String?)
                        ForEach(store.folders()) { Text(L10n.folderName($0.name)).tag(Optional($0.id)) }
                    }.accessibilityIdentifier("challenge.folderPicker")
                }
                Text(L10n.text("This choice stays on this device. Existing blocked tags and artists still apply.")).font(.caption).foregroundStyle(.secondary)
            }.navigationTitle(L10n.text("Image Source"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(L10n.text("Cancel")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.text("Done")) {
                        controller.source(kind: kind, servers: serverIDs, folder: folderID); dismiss()
                    }.disabled(kind == "servers" ? serverIDs.isEmpty : folderID == nil).accessibilityIdentifier("challenge.sourceDone")
                }
            }
            .onAppear {
                kind = controller.session.sourceKind
                serverIDs = controller.session.serverIDs.isEmpty ? store.selectedServerIDs : controller.session.serverIDs
                folderID = controller.session.folderID
            }
            .sheet(isPresented: $addingServer) { BooruServerEditor(server: nil) }
        }
    }
}
