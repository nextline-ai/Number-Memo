import SwiftUI

struct TasteTagDetail: View {
    let tag: TasteTag
    let mode: TasteMode
    @Environment(AppEnvironment.self) private var env
    @State private var searching = false
    @State private var opened: TasteRecommendation?
    private var excluded: Bool { env.taste.control.excluded.contains(tag.id) }
    private var sourceConnected: Bool { mode == .comics ? env.isSiteVerified : env.booru.servers.contains { $0.canonicalAddress == tag.source } }
    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    Label(TastePresentation.category(tag), systemImage: tag.discovery ? "sparkles" : "heart")
                        .font(.subheadline.weight(.medium)).foregroundStyle(TastePresentation.accent)
                    Text(TastePresentation.name(tag.name)).font(.largeTitle.bold()).textSelection(.enabled)
                    Text(TastePresentation.host(tag.source)).font(.subheadline).foregroundStyle(.secondary)
                    Button { searching = true } label: {
                        Label(L10n.text("Explore this tag"), systemImage: "magnifyingglass").foregroundStyle(.white).frame(maxWidth: .infinity).padding(.vertical, 6)
                    }.buttonStyle(.borderedProminent).tint(TastePresentation.accent).padding(.top, 4)
                        .disabled(!sourceConnected)
                    if !sourceConnected { Text(L10n.text("Connect this source in Settings to explore this tag.")).font(.footnote).foregroundStyle(.secondary) }
                }.padding(.vertical, 6)
            } footer: { Text(L10n.text("Recommendation searches send the selected tags to your connected websites. Your taste profile is not sent.")) }
            Section {
                LabeledContent(L10n.text("Saved works"), value: String(tag.count))
                LabeledContent(L10n.text("Confirmed by your choices"), value: String(tag.confirmed))
                LabeledContent(L10n.text("Saved without searching"), value: String(tag.hidden))
                if tag.general > 0 { LabeledContent(L10n.text("Other saved works"), value: String(tag.general)) }
                LabeledContent(L10n.text("Searches"), value: String(tag.searches))
                if let lift = tag.lift { Text(L10n.text("%@× as frequent in saved works", String(format: "%.1f", lift))) }
                if !tag.previouslySearched && tag.hidden > 0 && (tag.hidden < 5 || tag.sessions.count < 3) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(L10n.text("A pattern is taking shape")).font(.subheadline.weight(.medium))
                        Text(L10n.text("We look for at least 5 saved works across 3 browsing sessions before suggesting a hidden preference."))
                            .font(.footnote).foregroundStyle(.secondary)
                        ProgressView(value: Double(min(5, tag.hidden) + min(3, tag.sessions.count)), total: 8).tint(TastePresentation.accent)
                            .accessibilityLabel(L10n.text("Collecting evidence"))
                    }.padding(.vertical, 4)
                }
            } header: { Text(L10n.text("Your evidence")) }
              footer: { Text(L10n.text("Patterns describe your activity in this app. They are suggestions, not conclusions about you.")) }
            Section {
                ForEach(tag.works, id: \.key) { item in
                    TasteEvidenceRow(item: item, mode: mode) { post in
                        opened = .init(item: item, post: post, gallery: nil, reason: tag, score: 0)
                    }
                }
            } header: { Text(L10n.text("Supporting works")) }
              footer: { Text(L10n.text("Evidence comes from distinct saved works. Opening a work alone does not add preference points.")) }
            Section {
                Button {
                    env.taste.change { if excluded { $0.excluded.remove(tag.id) } else { $0.excluded.insert(tag.id) } }
                } label: {
                    Label(L10n.text(excluded ? "Include in recommendations" : "Exclude from recommendations"), systemImage: excluded ? "plus.circle" : "minus.circle")
                }.accessibilityIdentifier("taste.tag.exclude")
            }
        }.navigationTitle(L10n.text("Taste details")).navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("taste.tag.detail")
        .sheet(isPresented: $searching) {
            if mode == .booru, let server = env.booru.servers.first(where: { $0.canonicalAddress == tag.source }) {
                NavigationStack {
                    BooruFeedView(server: server, source: TasteSources.booru, initialQuery: tag.name)
                        .toolbar { ToolbarItem(placement: .topBarTrailing) { Button(L10n.text("Done")) { searching = false } } }
                }.environment(env.booru).environment(\.discoveryContext, DiscoveryContext(origin: .recommendation))
            } else {
                NativeContentView(source: TasteSources.comic, initialQuery: tag.name)
                    .environment(\.discoveryContext, DiscoveryContext(origin: .recommendation))
            }
        }
        .fullScreenCover(item: $opened) { TasteOpenedWork(item: $0) }
    }
}

private struct TasteEvidenceRow: View {
    let item: TasteItem
    let mode: TasteMode
    let open: (BooruPost?) -> Void
    @Environment(AppEnvironment.self) private var env
    @State private var post: BooruPost?
    @State private var work: Work?
    @State private var ready = false
    var body: some View {
        Button { open(post) } label: {
            HStack(spacing: 12) {
                Group {
                    if let post { TasteArtwork(post: post) }
                    else if let path = work?.thumbPath, let image = UIImage(contentsOfFile: path) { Image(uiImage: image).resizable().scaledToFill() }
                    else { Color.secondary.opacity(0.1).overlay { Image(systemName: mode == .booru ? "photo" : "book.closed").foregroundStyle(.secondary) } }
                }.frame(width: 52, height: 64).clipped().clipShape(RoundedRectangle(cornerRadius: 10)).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(work?.title ?? L10n.text("Work %@", String(item.id))).font(.subheadline.weight(.medium)).lineLimit(2).foregroundStyle(.primary)
                    Text(L10n.text(ready && mode == .booru && post == nil ? "No longer in your library" : "Saved works")).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
            }
        }.buttonStyle(.plain).disabled(!ready || (mode == .booru && post == nil))
        .task {
            if mode == .booru {
                post = env.booru.favorites(serverIDs: env.booru.servers.filter { $0.canonicalAddress == item.source }.map(\.id)).first { $0.postID == item.id }
            } else { work = try? env.database.getWork(galleryId: item.id) }
            ready = true
        }
    }
}

struct TasteTagList: View {
    let tags: [TasteTag]
    let mode: TasteMode
    @State private var query = ""
    var body: some View {
        List {
            ForEach(tags.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) || TastePresentation.name($0.name).localizedCaseInsensitiveContains(query) }) { tag in
                NavigationLink { TasteTagDetail(tag: tag, mode: mode) } label: {
                    VStack(alignment: .leading, spacing: 5) {
                        HStack { Text(TastePresentation.name(tag.name)).font(.headline); Spacer(); Text(String(tag.count)).monospacedDigit().foregroundStyle(.secondary) }
                        Text(TastePresentation.host(tag.source)).font(.caption).foregroundStyle(.secondary)
                    }.padding(.vertical, 4)
                }
            }
        }.navigationTitle(L10n.text("Recommendation evidence")).searchable(text: $query, prompt: L10n.text("Search tags"))
    }
}
