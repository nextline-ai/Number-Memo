import SwiftUI

/// Shared presentation values keep raw tags intact for queries and evidence.
enum TastePresentation {
    static let accent = Color.indigo
    static func name(_ tag: String) -> String { tag.replacingOccurrences(of: "_", with: " ") }
    static func host(_ source: String) -> String { URL(string: source)?.host ?? source }
    static func category(_ tag: TasteTag) -> String {
        L10n.text(tag.count == 0 ? "Searched tags" : tag.discovery ? "Hidden taste candidate" : tag.confirmed > 0 ? "Confirmed preference" : "Often saved together")
    }
    static func explanation(_ insight: TasteInsight, tag: TasteTag, snapshot: TasteSnapshot) -> String {
        switch insight.pattern {
        case .confirmed: return L10n.text("You chose and saved %@ works associated with this tag.", String(tag.confirmed))
        case .discovery: return L10n.text("You saved %@ works with this tag without searching for it, across %@ sessions.", String(tag.hidden), String(tag.sessions.count))
        case .frequent: return L10n.text("This tag appears in %@ of your saved works.", String(tag.count))
        case .rising: return L10n.text("Saved works with this tag increased from %@ to %@.", String(snapshot.previousTagCounts[tag.id, default: 0]), String(tag.count))
        case .association: return L10n.text("This tag often appears together with %@ in your saved works.", snapshot.tags.first { $0.id == insight.relatedKey }?.name ?? "")
        }
    }
}

enum TasteSources {
    static var booru: any BooruProviding {
        #if DEBUG
        if BooruUITestSupport.enabled { return BooruUITestSupport.source }
        #endif
        return BooruClient.shared
    }
    static var comic: any ContentProviding {
        #if DEBUG
        if ContentUITestSupport.enabled { return ContentUITestSupport.source }
        #endif
        return HitomiContentSource.shared
    }
    static let images = PageImageStore(source: comic)
}

struct TasteSurface<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        content.padding(18).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 22))
    }
}

struct TasteSectionHeading: View {
    let title: String
    var subtitle: String? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(L10n.text(title)).font(.title3.bold()).foregroundStyle(.primary)
            if let subtitle { Text(subtitle).font(.subheadline).foregroundStyle(.secondary) }
        }.accessibilityAddTraits(.isHeader)
    }
}

struct TasteTagRow: View {
    let tag: TasteTag
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: tag.discovery ? "sparkles" : "number")
                .font(.headline).foregroundStyle(TastePresentation.accent)
                .frame(width: 38, height: 38).background(TastePresentation.accent.opacity(0.09), in: RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 4) {
                Text(TastePresentation.name(tag.name)).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                Text(TastePresentation.category(tag)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 3) {
                Text(String(tag.count == 0 ? tag.searches : tag.count)).font(.headline.monospacedDigit()).foregroundStyle(.primary)
                Text(L10n.text(tag.count == 0 ? "Searches" : "Saved works")).font(.caption2).foregroundStyle(.secondary)
            }
            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
        }.padding(.vertical, 8).contentShape(Rectangle())
    }
}

struct TasteArtwork: View {
    var post: BooruPost? = nil
    var gallery: NativeGallery? = nil
    @Environment(AppEnvironment.self) private var env
    @State private var cover: UIImage?
    @State private var failed = false
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color(uiColor: .tertiarySystemFill)
                if let post, let server = env.booru.servers.first(where: { $0.id == post.serverID }) {
                    BooruThumbnail(post: post, server: server)
                } else if let cover {
                    Image(uiImage: cover).resizable().scaledToFill().frame(width: geometry.size.width, height: geometry.size.height).clipped()
                } else if gallery != nil && !failed { ProgressView() }
                else { Image(systemName: "book.closed").font(.largeTitle).foregroundStyle(.secondary) }
            }
        }
        .accessibilityHidden(true)
        .task(id: gallery?.id) {
            guard let gallery, let page = gallery.pages.first else { return }
            do { cover = try await TasteSources.images.load(page, galleryID: gallery.id, thumbnail: true) }
            catch { if !Task.isCancelled { failed = true } }
        }
    }
}

struct TasteRecommendationCard: View {
    let item: TasteRecommendation
    let open: () -> Void
    let toggle: () -> Void
    var isBookmarked = false
    @Environment(AppEnvironment.self) private var env
    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 6) {
                if let post = item.post, let server = env.booru.servers.first(where: { $0.id == post.serverID }) {
                    BooruPostThumbnailCard(post: post, server: server, showsFavoriteIndicator: true, isFavorite: env.booru.favoriteIDs.contains(post.id))
                } else if item.post != nil {
                    Color.secondary.opacity(0.12).aspectRatio(0.78, contentMode: .fit)
                        .overlay { Image(systemName: "photo").foregroundStyle(.secondary) }.clipShape(RoundedRectangle(cornerRadius: 16))
                } else if let gallery = item.gallery {
                    GalleryCardLayout(title: gallery.title, artists: gallery.artists.joined(separator: ", "), language: gallery.language, recommendationTag: TastePresentation.name(item.reason.name)) {
                        TasteArtwork(gallery: gallery)
                    }.overlay(alignment: .topLeading) {
                        if isBookmarked {
                            Image(systemName: "bookmark.fill").font(.system(size: 14, weight: .semibold)).foregroundStyle(.yellow)
                                .padding(8).background(.black.opacity(0.72), in: Circle()).padding(7).accessibilityHidden(true)
                        }
                    }
                }
                if item.gallery == nil { Label(TastePresentation.name(item.reason.name), systemImage: "number")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2).padding(.horizontal, 2) }
            }.contentShape(Rectangle())
        }.buttonStyle(.plain).hoverEffect(.highlight)
            .accessibilityIdentifier("taste.work.\(item.item.id)")
            .highPriorityGesture(LongPressGesture(minimumDuration: 0.55).onEnded { _ in toggle() })
            .accessibilityElement(children: .combine)
            .accessibilityValue(L10n.text(saved ? "Saved" : "Not bookmarked"))
            .accessibilityAction(named: L10n.text(saved ? "Remove Favorite" : "Bookmark"), toggle)
    }
    private var saved: Bool {
        if let post = item.post { return env.booru.favoriteIDs.contains(post.id) }
        return isBookmarked
    }
}

struct TasteOpenedWork: View {
    let item: TasteRecommendation
    var context = DiscoveryContext(origin: .recommendation)
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        if let post = item.post, let server = env.booru.servers.first(where: { $0.canonicalAddress == item.item.source }) {
            BooruPostView(post: post, posts: [post], server: server, source: TasteSources.booru)
                .environment(env.booru).environment(\.discoveryContext, context)
        } else if item.item.source == "https://hitomi.la" {
            ContentEntryView(initialUrl: HitomiUrls.galleryUrl(for: item.item.id))
                .environment(\.discoveryContext, context)
        } else {
            NavigationStack {
                ContentUnavailableView(L10n.text("Media Unavailable"), systemImage: "photo", description: Text(L10n.text("Connect this source in Settings to explore this tag.")))
                    .toolbar { ToolbarItem(placement: .topBarTrailing) { Button(L10n.text("Done")) { dismiss() } } }
            }
        }
    }
}
