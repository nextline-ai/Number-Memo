import SwiftUI
import GRDB

public struct ArtistsListView: View {
    @Environment(AppEnvironment.self) private var env

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
                            let target = HitomiUrls.artistAllUrl(for: artist.name)
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
        .task {
            do {
                let observation = ValueObservation.tracking { db in
                    try [Row.fetchAll(db, sql: "SELECT * FROM works"), Row.fetchAll(db, sql: "SELECT * FROM folders"), Row.fetchAll(db, sql: "SELECT * FROM folder_works"), Row.fetchAll(db, sql: "SELECT * FROM artists")]
                }
                for try await _ in observation.values(in: env.database.dbWriter) { loadArtists() }
            } catch { loadArtists() }
        }
    }

    private func loadArtists() {
        if let list = try? env.database.listArtists() {
            self.artists = list
        }
    }

    private func removeArtist(_ name: String) {
        try? env.database.removeFavoriteArtist(name: name)
        loadArtists()
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
