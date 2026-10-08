import SwiftUI

struct VisualSimilaritySeed: Identifiable {
    var work: Work? = nil
    var post: BooruPost? = nil
    var id: String { post?.id ?? "comic:\(work?.galleryId ?? 0)" }
}
struct VisualSimilarityView: View {
    let seed: VisualSimilaritySeed
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    @State private var works: [Work] = []
    @State private var posts: [BooruPost] = []
    @State private var loading = true
    @State private var completed = 0
    @State private var total = 0
    @State private var failed = false
    @State private var missing = 0
    @State private var opened: TasteRecommendation?
    @State private var feedback: WorkSaveFeedback?
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(L10n.text("Find similar art styles in your saved works. Visual similarity also reflects composition, colors and subjects. Images and fingerprints stay on this device."))
                        .font(.subheadline).foregroundStyle(.secondary)
                    if loading {
                        ProgressView(value: Double(completed), total: Double(max(1, total)))
                        Text(L10n.text("Preparing saved thumbnails: %@ / %@", String(completed), String(total))).font(.caption).foregroundStyle(.secondary)
                    } else if failed {
                        ContentUnavailableView(L10n.text("Thumbnail unavailable"), systemImage: "photo.badge.exclamationmark", description: Text(L10n.text("Load this work's thumbnail and try again.")))
                    } else if works.isEmpty && posts.isEmpty {
                        ContentUnavailableView(L10n.text("No similar saved works yet"), systemImage: "photo.on.rectangle.angled")
                    }
                    if missing > 0 && !loading {
                        Text(L10n.text("Some saved thumbnails could not be read. Available works are shown."))
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    LazyVGrid(columns: WorkGridLayout.columns(env.gridColumns(for: seed.post == nil ? .hitomi : .booru)), spacing: 16) {
                        ForEach(works) { work in
                            Button { open(work) } label: { WorkCardView(work: work) }.buttonStyle(.plain)
                        }
                    }
                    if let post = seed.post, let server = env.booru.servers.first(where: { $0.id == post.serverID }) {
                        BooruPostGrid(posts: posts, server: server, feedback: { feedback = $0 }, open: { open($0, server: server) })
                    }
                }.padding(20)
            }.navigationTitle(L10n.text("Similar art styles")).navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .topBarTrailing) { Button(L10n.text("Done")) { dismiss() } } }
                .task { await load() }
                .tasteWorkPresentation($opened) { _ in .init(origin: .library) }
                .workSaveFeedback($feedback, identifier: "similarity.feedback")
        }.presentationDetents([.large]).presentationDragIndicator(.visible)
    }
    private func open(_ work: Work) {
        let item = TasteItem.comic(work.galleryId, tags: work.tags)
        opened = .init(item: item, post: nil, gallery: nil, reason: .init(source: item.source, name: ""), score: 0)
    }
    private func open(_ post: BooruPost, server: BooruServer) {
        let item = TasteItem(source: server.canonicalAddress, id: post.postID, tags: post.tags)
        opened = .init(item: item, post: post, gallery: nil, reason: .init(source: item.source, name: ""), score: 0)
    }
    @MainActor private func load() async {
        do {
            if let work = seed.work {
                let database = env.database
                let saved = try await Task.detached(priority: .utility) { try database.listWorks() }.value
                let store = VisualFingerprintStore(database: database.dbWriter)
                var prints = try store.all(scope: "comics")
                total = saved.count
                for item in saved {
                    try Task.checkCancellation()
                    if prints[item.galleryId] == nil, let path = item.thumbPath {
                        if let data = try? await Task.detached(priority: .utility, operation: { try Data(contentsOf: URL(fileURLWithPath: path)) }).value {
                            prints[item.galleryId] = try? await store.save(data: data, scope: "comics", id: item.galleryId)
                        }
                    }
                    if prints[item.galleryId] == nil { missing += 1 }
                    completed += 1
                }
                guard let target = prints.removeValue(forKey: work.galleryId) else { failed = true; loading = false; return }
                let ranked = try await VisualFingerprintEngine.shared.rank(seed: target, candidates: prints)
                let lookup = Dictionary(uniqueKeysWithValues: saved.map { ($0.galleryId, $0) })
                works = ranked.prefix(100).compactMap { lookup[$0.0] }
            } else if let post = seed.post, let server = env.booru.servers.first(where: { $0.id == post.serverID }) {
                let saved = env.booru.favorites(serverID: server.id)
                let store = VisualFingerprintStore(database: env.booru.database)
                var prints = try store.all(scope: server.id)
                total = saved.count
                for item in saved {
                    try Task.checkCancellation()
                    if prints[item.postID] == nil, let url = item.previewURL ?? item.sampleURL {
                        if let image = try? await BooruThumbnailCache.shared.image(url: url, server: server), let data = image.jpegData(compressionQuality: 0.9) {
                            prints[item.postID] = try? await store.save(data: data, scope: server.id, id: item.postID)
                        }
                    }
                    if prints[item.postID] == nil { missing += 1 }
                    completed += 1
                }
                guard let target = prints.removeValue(forKey: post.postID) else { failed = true; loading = false; return }
                let ranked = try await VisualFingerprintEngine.shared.rank(seed: target, candidates: prints)
                let lookup = Dictionary(uniqueKeysWithValues: saved.map { ($0.postID, $0) })
                posts = ranked.prefix(100).compactMap { lookup[$0.0] }
            }
            loading = false
        } catch is CancellationError { }
        catch { failed = true; loading = false }
    }
}
