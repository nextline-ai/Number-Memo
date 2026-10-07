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
            try Data.fetchAll(db, sql: "SELECT payload FROM favorites").map { try Self.tasteItem(JSONDecoder().decode(BooruPost.self, from: $0), db: db) }
        }
    }
}
extension AppDatabase {
    var tasteStore: TasteStore { .init(database: dbWriter, mode: .comics) }
    func observeTaste(_ gallery: NativeGallery, context: DiscoveryContext) throws {
        try tasteStore.record(.open, item: .init(source: "https://hitomi.la", id: gallery.id, tags: gallery.tags), context: context)
    }
    func recordTasteSearch(_ context: DiscoveryContext) throws {
        guard context.origin == .search, !context.included.isEmpty else { return }
        try tasteStore.record(.search, item: .init(source: "https://hitomi.la", id: 0, tags: Array(context.included)), context: context)
    }
    func tasteLibrary() throws -> [TasteItem] {
        try dbWriter.read { db in try Row.fetchAll(db, sql: "SELECT gallery_id, tags FROM works").map { TasteItem.comic($0["gallery_id"], tags: $0["tags"]) } }
    }
}

@MainActor enum TasteRecommendationAction {
    static func toggle(_ item: TasteRecommendation, env: AppEnvironment, session: String) throws -> String {
        let context = DiscoveryContext.recommended(item.reason.name, session: session)
        if let post = item.post {
            try env.booru.toggleFavorite(post, context: context)
            return L10n.text(env.booru.isFavorite(post) ? "Saved" : "Bookmark removed")
        }
        return try ContentBookmarkAction.toggle(id: item.item.id, gallery: item.gallery, env: env, images: TasteSources.images, context: context)
    }
}
