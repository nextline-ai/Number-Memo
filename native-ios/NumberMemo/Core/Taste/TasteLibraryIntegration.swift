import Foundation
import GRDB

extension BooruStore {
    var tasteStore: TasteStore { .init(database: database, mode: .booru) }
    static func tasteItem(_ post: BooruPost, db: Database) throws -> TasteItem {
        let data = try Data.fetchOne(db, sql: "SELECT payload FROM servers WHERE id = ?", arguments: [post.serverID])
        let source = try data.map { try JSONDecoder().decode(BooruServer.self, from: $0).canonicalAddress } ?? post.serverID
        return .init(source: source, id: post.postID, tags: post.tags, metadata: post.metadataTags ?? [])
    }
    func observeTaste(_ post: BooruPost, context: DiscoveryContext) throws {
        try database.write { try TasteStore.record(.open, item: Self.tasteItem(post, db: $0), context: context, db: $0) }
    }
    func recordTasteSearch(_ context: DiscoveryContext, servers: [BooruServer]) throws {
        guard context.origin == .search, !context.included.isEmpty else { return }
        try database.write { db in
            for server in servers { try TasteStore.record(.search, item: .init(source: server.canonicalAddress, id: 0, tags: Array(context.included)), context: context, db: db) }
        }
    }
    func tasteLibrary() throws -> [TasteItem] {
        try database.read { db in
            // Resolve each server once, rather than re-reading and decoding its
            // payload for every favorite during first-launch analysis bootstrap.
            let servers = try Data.fetchAll(db, sql: "SELECT payload FROM servers").map { try JSONDecoder().decode(BooruServer.self, from: $0) }
            let addresses = Dictionary(servers.map { ($0.id, $0.canonicalAddress) }, uniquingKeysWith: { first, _ in first })
            return try Data.fetchAll(db, sql: "SELECT payload FROM favorites").map {
                let post = try JSONDecoder().decode(BooruPost.self, from: $0)
                return .init(source: addresses[post.serverID] ?? post.serverID, id: post.postID, tags: post.tags, metadata: post.metadataTags ?? [])
            }
        }
    }
}
extension AppDatabase {
    var tasteStore: TasteStore { .init(database: dbWriter, mode: .comics) }
    func observeTaste(_ gallery: NativeGallery, context: DiscoveryContext) throws {
        try tasteStore.record(.open, item: .init(source: MangaUrls.source, id: gallery.id, tags: gallery.tags), context: context)
    }
    func recordTasteSearch(_ context: DiscoveryContext) throws {
        guard context.origin == .search, !context.included.isEmpty else { return }
        try tasteStore.record(.search, item: .init(source: MangaUrls.source, id: 0, tags: Array(context.included)), context: context)
    }
    func tasteLibrary() throws -> [TasteItem] {
        try dbWriter.read { db in try Row.fetchAll(db, sql: "SELECT gallery_id, tags FROM works").map { TasteItem.comic($0["gallery_id"], tags: $0["tags"]) } }
    }
}

@MainActor enum TasteRecommendationAction {
    static func toggle(_ item: TasteRecommendation, env: AppEnvironment, session: String) throws -> WorkSaveResult {
        let context = DiscoveryContext.recommended(item.reason.name, session: session)
        if let post = item.post {
            return try BooruFavoriteAction.toggle(post, store: env.booru, context: context)
        }
        return try ContentBookmarkAction.toggle(id: item.item.id, gallery: item.gallery, env: env, images: TasteSources.images, context: context)
    }
}
