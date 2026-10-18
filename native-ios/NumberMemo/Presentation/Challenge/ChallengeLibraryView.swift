import SwiftUI
import UniformTypeIdentifiers

struct ChallengeLibraryView: View {
    let source: any BooruProviding
    @Environment(BooruStore.self) private var booru
    @State private var games: [ChallengeDefinition] = []
    @State private var sessionIDs: Set<String> = []
    @State private var busy: String?
    @State private var reloadTask: Task<Void, Never>?
    @State private var editing: ChallengeDefinition?
    @State private var playing: ChallengeDefinition?
    @State private var backingUp: ChallengeDefinition?
    @State private var deleting: ChallengeDefinition?
    @State private var error: String?
    private var store: ChallengeStore { .init(booru) }
    var body: some View {
        List {
            Section {
                Button {
                    run(L10n.text("Loading…")) { playing = try await Task.detached { [store] in try store.example() }.value }
                } label: {
                    HStack(spacing: 14) {
                        Image(systemName: "pencil.and.outline").font(.title3).foregroundStyle(.purple)
                            .frame(width: 42, height: 48)
                            .background(.purple.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                        VStack(alignment: .leading, spacing: 4) {
                            Text(L10n.text("Croquis Challenge")).font(.headline).foregroundStyle(Color.primary)
                            Text(L10n.text("Choose a reference and practice a quick sketch.")).font(.caption).foregroundStyle(Color.secondary)
                        }
                        Spacer()
                    }.padding(.vertical, 4)
                }.accessibilityIdentifier("challenge.example")
            }
            Section {
                ForEach(games) { game in
                    let continuing = sessionIDs.contains(game.id)
                    HStack {
                    Button { playing = game } label: {
                        HStack(spacing: 14) {
                            Image(systemName: game.goal.mode == .time ? "timer" : "dice")
                                .font(.title3).foregroundStyle(.purple).frame(width: 42, height: 48)
                                .background(.purple.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                            VStack(alignment: .leading, spacing: 4) {
                                Text(game.title).font(.headline).foregroundStyle(Color.primary)
                                if !game.detail.isEmpty { Text(game.detail).font(.caption).foregroundStyle(Color.secondary).lineLimit(2) }
                            }
                            Spacer()
                            VStack(spacing: 5) {
                                Image(systemName: continuing ? "play.circle.fill" : "play.circle").font(.title2)
                                Text(L10n.text(continuing ? "Continue" : "Play")).font(.caption2.weight(.semibold))
                            }.foregroundStyle(.purple)
                        }
                    }.accessibilityIdentifier("challenge.game.\(game.id)")
                    Menu { gameActions(game) } label: {
                        Image(systemName: "ellipsis").padding(.vertical, 16).padding(.leading, 8)
                    }.accessibilityLabel(L10n.text("Challenge Settings"))
                        .accessibilityIdentifier("challenge.actions.\(game.id)")
                    }.buttonStyle(.borderless)
                    .contextMenu { gameActions(game) }
                    .swipeActions(edge: .trailing) {
                        Button(L10n.text("Delete"), role: .destructive) { deleting = game }
                        Button(L10n.text("Edit")) { editing = game }.tint(.purple)
                    }
                }
                Button(L10n.text("New Challenge"), systemImage: "plus") {
                    var game = ChallengeDefinition.croquis(); game.title = L10n.text("New Challenge"); editing = game
                }.accessibilityIdentifier("challenge.new").font(.headline).tint(.purple)
            } header: { Text(L10n.text("My Challenges")) } footer: {
                Text(L10n.text("Challenge definitions follow your iCloud setting. Progress and image sources stay on this device."))
            }
            Section {
                NavigationLink { ChallengeBackupView() } label: { Label(L10n.text("Challenge Backup and Import"), systemImage: "externaldrive") }
                    .accessibilityIdentifier("challenge.backup")
            }
        }
        .listStyle(.insetGrouped)
        .tint(.purple)
        .disabled(busy != nil)
        .overlay {
            if let busy {
                VStack(spacing: 12) {
                    ProgressView().controlSize(.large)
                    Text(busy).font(.subheadline.weight(.semibold))
                }.padding(28).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
                    .accessibilityIdentifier("challenge.loading")
            }
        }
        .navigationTitle(L10n.text("Challenge Roulette"))
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $editing, onDismiss: reload) { game in
            ChallengeEditorView(game: game, store: store)
        }
        .sheet(item: $backingUp) { game in
            NavigationStack {
                ChallengeBackupView(selected: game)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button(L10n.text("Done")) { backingUp = nil } } }
            }
        }
        .fullScreenCover(item: $playing, onDismiss: reload) { game in
            NavigationStack { ChallengePlayHost(game: game, store: store, source: source) }
        }
        .alert(L10n.text("Delete Challenge?"), isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button(L10n.text("Cancel"), role: .cancel) { deleting = nil }
            Button(L10n.text("Delete"), role: .destructive) {
                guard let game = deleting else { return }
                deleting = nil
                run(L10n.text("Deleting…")) {
                    try await Task.detached { [store] in try store.delete(game.id) }.value
                    games.removeAll { $0.id == game.id }; sessionIDs.remove(game.id)
                }
            }
        } message: { Text(L10n.text("This removes the definition and progress. Definition deletions also sync when iCloud is enabled.")) }
        .challengeError($error)
        .onAppear(perform: reload)
        .onChange(of: booru.revision) { _, _ in reload() }
    }
    @ViewBuilder private func gameActions(_ game: ChallengeDefinition) -> some View {
        Button(L10n.text("Edit"), systemImage: "pencil") { editing = game }
        Button(L10n.text("Duplicate"), systemImage: "plus.square.on.square") {
            var copy = game; copy.id = UUID().uuidString; copy.title = String(copy.title.prefix(190)) + " " + L10n.text("Copy"); editing = copy
        }
        Button(L10n.text("Export Challenge Backup"), systemImage: "square.and.arrow.up") { backingUp = game }
        Button(L10n.text("Delete"), systemImage: "trash", role: .destructive) { deleting = game }
    }
    private func reload() {
        reloadTask?.cancel()
        guard busy == nil else { return }
        reloadTask = Task {
            do {
                let values = try await Task.detached { [store] in (try store.definitions(), try store.sessionIDs()) }.value
                guard !Task.isCancelled else { return }
                games = values.0; sessionIDs = values.1
            } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
        }
    }
    private func run(_ label: String, action: @escaping @MainActor () async throws -> Void) {
        guard busy == nil else { return }
        reloadTask?.cancel(); busy = label
        Task {
            do { try await action() } catch { self.error = error.localizedDescription }
            busy = nil; reload()
        }
    }
}

struct ChallengeBackupDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { .init(regularFileWithContents: data) }
}

struct ChallengeBackupView: View {
    var selected: ChallengeDefinition?
    @Environment(BooruStore.self) private var booru
    @State private var picking = false
    @State private var exporting = false
    @State private var document = ChallengeBackupDocument(data: Data())
    @State private var busy = false
    @State private var message: String?
    @State private var error: String?
    var body: some View {
        Form {
            Section {
                Button(L10n.text("Export Challenge Backup"), systemImage: "square.and.arrow.up") {
                    do {
                        let games = try selected.map { [$0] } ?? ChallengeStore(booru).definitions()
                        document = .init(data: try ChallengeBackup(games: games).encoded()); exporting = true
                    } catch { self.error = error.localizedDescription }
                }.accessibilityIdentifier("challenge.export")
                Button(L10n.text("Import Challenge Backup"), systemImage: "square.and.arrow.down") { picking = true }
                    .accessibilityIdentifier("challenge.import")
            } footer: { Text(L10n.text("Back up challenge definitions only. Images, accounts, image sources and progress are not included. Maximum file size: 10 MB.")) }
            if busy { ProgressView() }
        }.tint(.purple).navigationTitle(L10n.text("Challenge Backup and Import")).navigationBarTitleDisplayMode(.inline)
        .disabled(busy)
        .fileImporter(isPresented: $picking, allowedContentTypes: [.json]) { result in
            switch result {
            case .failure(let error): self.error = error.localizedDescription
            case .success(let url):
                busy = true
                Task {
                    defer { busy = false }
                    do {
                        let store = ChallengeStore(booru)
                        try await Task.detached {
                            let backup = try ChallengeBackup.read(url)
                            try store.restore(backup, replace: false)
                        }.value
                        message = L10n.text("Challenges imported successfully.")
                    }
                    catch { self.error = error.localizedDescription }
                }
            }
        }
        .fileExporter(isPresented: $exporting, document: document, contentType: .json, defaultFilename: "number-memo-challenges.json") { result in
            if case .failure(let error) = result { self.error = error.localizedDescription }
        }
        .challengeError($error)
        .transientMessage($message)
    }
}

private struct ChallengeErrorModifier: ViewModifier {
    @Binding var error: String?
    func body(content: Content) -> some View {
        content.alert(L10n.text("Unable to Continue"), isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button(L10n.text("OK")) { error = nil }
        } message: { Text(error ?? "") }
    }
}
extension View {
    func challengeError(_ error: Binding<String?>) -> some View { modifier(ChallengeErrorModifier(error: error)) }
}
