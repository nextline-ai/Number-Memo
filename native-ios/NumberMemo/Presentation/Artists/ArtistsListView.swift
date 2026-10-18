import SwiftUI
import GRDB

public struct ArtistsListView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.scenePhase) private var scenePhase

    @State private var artists: [ArtistMemo] = []
    @State private var selectedBrowserItem: IdentifiableURL?

    public init() {}

    public var body: some View {
        List {
            if artists.isEmpty {
                ContentUnavailableView(
                    L10n.text("No Favorite Artists"),
                    systemImage: "person.2",
                    description: Text(L10n.text("Tap the star (★) beside an artist on the work details screen to add them."))
                )
            } else {
                ForEach(artists) { artist in
                    NavigationLink {
                        WorksGridView(artist: artist.name)
                    } label: {
                        ArtistRowView(artist: artist) {
                            let target = MangaUrls.artistAllUrl(for: artist.name)
                            selectedBrowserItem = IdentifiableURL(url: target)
                        }
                    }
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            removeArtist(artist.name)
                        } label: {
                            Label(L10n.text("Delete"), systemImage: "trash")
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .principal) { AppModeSwitch() }
            ToolbarItem(placement: .topBarLeading) {
                LiquidGlassTitleCapsule(L10n.text("Artists"))
            }
        }
        .fullScreenCover(item: $selectedBrowserItem) { item in
            ContentEntryView(initialUrl: item.url)
        }
        .task(id: env.mode == .manga && scenePhase == .active) {
            guard env.mode == .manga, scenePhase == .active else { return }
            do {
                let observation = ValueObservation.tracking { db in
                    try ArtistMemo.order(ArtistMemo.Columns.name.asc).fetchAll(db)
                }
                for try await updatedArtists in observation.removeDuplicates().values(in: env.database.dbWriter, bufferingPolicy: .bufferingNewest(1)) {
                    try Task.checkCancellation()
                    artists = updatedArtists
                }
            } catch { }
        }
    }

    private func removeArtist(_ name: String) {
        try? env.database.removeFavoriteArtist(name: name)
    }
}

private struct ArtistRowView: View {
    let artist: ArtistMemo
    let onOpenBrowser: () -> Void

    var body: some View {
        HStack {
            Image(systemName: "star.fill")
                .foregroundColor(.yellow)
                .font(.caption)

            Text(artist.name)
                .font(.headline)

            Spacer()

            Button(action: onOpenBrowser) {
                Image(systemName: "safari")
                    .foregroundColor(.blue)
            }
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 4)
    }
}

private struct IdentifiableURL: Identifiable {
    let id = UUID()
    let url: String
}
