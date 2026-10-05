import SwiftUI
import UniformTypeIdentifiers

public struct SettingsView: View {
    @Environment(AppEnvironment.self) private var env

    @State private var showReaderHelp = false
    @State private var showReaderSettings = false
    @State private var worksCount = 0
    @State private var catalogCount = 0
    @State private var missingCount = 0
    @State private var statusMessage: String?
    @State private var isImporting = false
    @State private var showUserDbPicker = false
    @State private var showDataDbPicker = false
    @State private var showDataDbActionSheet = false
    @State private var showNoWorksAlert = false
    @State private var pendingDataDbUrl: URL? = nil
    @State private var importTask: Task<Void, Never>? = nil
    @State private var showShareSheet = false
    @State private var showBackupPicker = false
    @State private var backupFileURL: URL?
    @State private var showOnboardingFlow = false

    public init() {}

    public var body: some View {
        @Bindable var bindableEnv = env

        List {
            LanguageSettingsSection()
            Section {
                Button(L10n.text("Replay Onboarding"), systemImage: "sparkles") { showOnboardingFlow = true }
                    .accessibilityIdentifier("settings.onboarding")
            }
            Section(header: Text(L10n.text("Website Connection"))) {
                HStack {
                    Label(
                        env.isSiteVerified ? L10n.text("Service Enabled (hitomi.la)") : L10n.text("Connection Disabled"),
                        systemImage: env.isSiteVerified ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
                    )
                    .foregroundColor(env.isSiteVerified ? .green : .orange)

                    Spacer()

                    Button(L10n.text("Reset Address")) {
                        showOnboardingFlow = true
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                if !env.isSiteVerified {
                    Text(L10n.text("Enter the correct address (hitomi.la) to enable the library and shortcuts."))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Section(header: Text(L10n.text("Library Status"))) {
                LabeledContent(L10n.text("Saved Works"), value: L10n.text("%@ items", String(describing: worksCount)))
                LabeledContent(L10n.text("Catalog Matches"), value: L10n.text("%@ items", String(describing: catalogCount)))
                LabeledContent(L10n.text("Missing Titles"), value: L10n.text("%@ items", String(describing: missingCount)))
            }

            Section(header: Text(L10n.text("Automatic Fetching"))) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(L10n.text("Fill Covers, Titles, and Tags"))
                                .font(.headline)
                            if env.coverQueueState.isRunning && env.coverQueueState.total > 0 {
                                Text(queueProgressText)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            } else {
                                Text(L10n.text("Fetch missing covers and metadata in the background."))
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }

                        Spacer()

                        Button(action: toggleQueue) {
                            Image(systemName: env.coverQueueState.isRunning && !env.coverQueueState.isPaused ? "pause.circle.fill" : "play.circle.fill")
                                .font(.title2)
                                .foregroundColor(.accentColor)
                        }
                    }

                    if env.coverQueueState.isRunning && env.coverQueueState.total > 0 {
                        ProgressView(
                            value: queueProgressValue,
                            total: Double(max(1, env.coverQueueState.total))
                        )
                    }
                }
                .padding(.vertical, 4)
            }

            ModeAppearanceSettings()
            HitomiDefaultTagsSettings()

            Section(header: Text(L10n.text("Behavior"))) {
                Button(L10n.text("Reader Settings")) { showReaderSettings = true }
                Button(L10n.text("Reader Guide")) { showReaderHelp = true }
                Toggle(L10n.text("Open in Built-in Browser"), isOn: $bindableEnv.useEmbeddedBrowser)
                    .accessibilityIdentifier("settings.embeddedBrowser")
                Text(L10n.text("Use the website if the native viewer stops working. Turn off to return to the native viewer."))
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section(header: Text(L10n.text("Import Data (Violet)"))) {
                Button {
                    showUserDbPicker = true
                } label: {
                    Label(L10n.text("Import user.db (Bookmarks, Folders, Artists)"), systemImage: "person.crop.rectangle.stack")
                }
                .disabled(isImporting)

                Button {
                    showDataDbPicker = true
                } label: {
                    Label(L10n.text("Import data.db (Work Metadata Catalog)"), systemImage: "cylinder.split.1x2")
                }
                .disabled(isImporting)
            }

            Section(header: Text(L10n.text("Backup & Restore (iCloud Compatible)"))) {
                Button {
                    exportBackup()
                } label: {
                    Label(L10n.text("Export JSON Backup"), systemImage: "square.and.arrow.up")
                }
                .disabled(isImporting)

                Button {
                    showBackupPicker = true
                } label: {
                    Label(L10n.text("Import / Restore JSON Backup"), systemImage: "square.and.arrow.down")
                }
                .disabled(isImporting)
            }

            if isImporting || statusMessage != nil {
                Section(header: Text(L10n.text("Task Status"))) {
                    if isImporting {
                        HStack(spacing: 12) {
                            ProgressView()
                            Text(statusMessage ?? L10n.text("Processing…"))
                                .font(.footnote)
                            Spacer()
                            Button(L10n.text("Cancel")) {
                                importTask?.cancel()
                                isImporting = false
                                statusMessage = L10n.text("The task was canceled.")
                            }
                            .buttonStyle(.bordered)
                            .tint(.red)
                            .controlSize(.small)
                        }
                    } else if let statusMessage {
                        Text(statusMessage)
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    }
                }
            }
            SearchHistorySettings(booru: false)
            CloudSyncSection()
            DeveloperInfoSection()
        }
        .listStyle(.insetGrouped)
        .sheet(isPresented: $showReaderSettings) { ReaderSettingsView() }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .principal) { AppModeSwitch() }
            ToolbarItem(placement: .topBarLeading) {
                LiquidGlassTitleCapsule(L10n.text("Settings"))
            }
        }
        .fullScreenCover(isPresented: $showOnboardingFlow) {
            OnboardingView()
                .environment(env)
        }
        .fileImporter(
            isPresented: $showUserDbPicker,
            allowedContentTypes: [.item],
            allowsMultipleSelection: false
        ) { result in
            handleUserDbImport(result: result)
        }
        .fileImporter(
            isPresented: $showDataDbPicker,
            allowedContentTypes: [.item],
            allowsMultipleSelection: false
        ) { result in
            handleDataDbSelection(result: result)
        }
        .fileImporter(
            isPresented: $showBackupPicker,
            allowedContentTypes: [.json, .item],
            allowsMultipleSelection: false
        ) { result in
            handleBackupImport(result: result)
        }
        .confirmationDialog(
            L10n.text("How to Import data.db (Catalog)"),
            isPresented: $showDataDbActionSheet,
            titleVisibility: .visible
        ) {
            Button(L10n.text("⚡️ Fill Only My Library (Recommended)")) {
                if let url = pendingDataDbUrl {
                    startDataDbImport(url: url, matchOnly: true)
                }
            }
            Button(L10n.text("📦 Save Entire Catalog (Background Import)")) {
                if let url = pendingDataDbUrl {
                    startDataDbImport(url: url, matchOnly: false)
                }
            }
            Button(L10n.text("Cancel"), role: .cancel) {
                pendingDataDbUrl = nil
            }
        } message: {
            Text(L10n.text("data.db is a large catalog that can exceed 500 MB.\n\nChoose 'Fill Only My Library' to extract information for your %@ saved works. This avoids storing hundreds of thousands of unnecessary records.", String(describing: worksCount)))
        }
        .alert(L10n.text("Your Library Is Empty"), isPresented: $showNoWorksAlert) {
            Button(L10n.text("Save Entire Catalog")) {
                if let url = pendingDataDbUrl {
                    startDataDbImport(url: url, matchOnly: false)
                }
            }
            Button(L10n.text("Cancel (Import user.db First)"), role: .cancel) {
                pendingDataDbUrl = nil
            }
        } message: {
            Text(L10n.text("There are no saved works to match. Import user.db (bookmarks) first, then import data.db to fill the information you need."))
        }
        .sheet(isPresented: $showReaderHelp) { ReaderHelpView() }
        .sheet(isPresented: $showShareSheet) {
            if let backupFileURL {
                ShareSheet(items: [backupFileURL])
            }
        }
        .task {
            loadStats()
        }
    }

    private var queueProgressText: String {
        let state = env.coverQueueState
        let done = state.processed + state.failed + state.gone
        return L10n.text("%@/%@ (failed: %@, unavailable: %@)", String(describing: done), String(describing: state.total), String(describing: state.failed), String(describing: state.gone))
    }

    private var queueProgressValue: Double {
        let state = env.coverQueueState
        return Double(state.processed + state.failed + state.gone)
    }

    private func loadStats() {
        worksCount = (try? env.database.worksCount()) ?? 0
        catalogCount = (try? env.database.catalogCount()) ?? 0
        missingCount = (try? env.database.missingTitleCount()) ?? 0
    }

    private func toggleQueue() {
        if env.coverQueueState.isRunning {
            if env.coverQueueState.isPaused {
                Task { await env.coverQueueActor.resume() }
                env.coverQueueState.isPaused = false
            } else {
                Task { await env.coverQueueActor.pause() }
                env.coverQueueState.isPaused = true
            }
        } else {
            env.startCoverQueue()
        }
    }

    private func handleDataDbSelection(result: Result<[URL], Error>) {
        guard case .success(let urls) = result, let url = urls.first else { return }
        pendingDataDbUrl = url
        loadStats()
        if worksCount > 0 {
            showDataDbActionSheet = true
        } else {
            showNoWorksAlert = true
        }
    }

    private func handleUserDbImport(result: Result<[URL], Error>) {
        guard case .success(let urls) = result, let url = urls.first else { return }
        isImporting = true
        statusMessage = L10n.text("Preparing user.db…")

        let importer = env.violetImporter
        let envRef = env

        importTask = Task.detached(priority: .userInitiated) {
            let hasAccess = url.startAccessingSecurityScopedResource()
            defer {
                if hasAccess { url.stopAccessingSecurityScopedResource() }
            }

            var readPath = url.path
            var tempURL: URL? = nil

            if !VioletImportService.isUserDb(at: readPath) {
                let tempDir = FileManager.default.temporaryDirectory
                let copyUrl = tempDir.appendingPathComponent("\(UUID().uuidString)_\(url.lastPathComponent)")
                do {
                    try? FileManager.default.removeItem(at: copyUrl)
                    try FileManager.default.copyItem(at: url, to: copyUrl)
                    readPath = copyUrl.path
                    tempURL = copyUrl
                } catch {
                    await MainActor.run {
                        self.isImporting = false
                        self.statusMessage = L10n.text("Unable to read file: %@", String(describing: error.localizedDescription))
                    }
                    return
                }
            }

            defer {
                if let tempURL {
                    try? FileManager.default.removeItem(at: tempURL)
                }
            }

            do {
                let res = try importer.importUserDb(path: readPath)
                await MainActor.run {
                    self.isImporting = false
                    self.statusMessage = L10n.text("user.db imported: %@ folders, %@ works, %@ artists", String(describing: res.folders), String(describing: res.works), String(describing: res.artists))
                    self.loadStats()
                    envRef.startCoverQueue()
                }
            } catch {
                await MainActor.run {
                    self.isImporting = false
                    self.statusMessage = L10n.text("Import failed: %@", String(describing: error.localizedDescription))
                }
            }
        }
    }

    private func startDataDbImport(url: URL, matchOnly: Bool) {
        isImporting = true
        statusMessage = matchOnly ? L10n.text("Matching metadata for your library…") : L10n.text("Preparing catalog import…")

        let importer = env.violetImporter

        importTask = Task.detached(priority: .userInitiated) {
            let hasAccess = url.startAccessingSecurityScopedResource()
            defer {
                if hasAccess { url.stopAccessingSecurityScopedResource() }
            }

            var readPath = url.path
            var tempURL: URL? = nil

            if !VioletImportService.isDataDb(at: readPath) {
                await MainActor.run {
                    self.statusMessage = L10n.text("Caching large file… Please wait.")
                }
                let tempDir = FileManager.default.temporaryDirectory
                let copyUrl = tempDir.appendingPathComponent("\(UUID().uuidString)_\(url.lastPathComponent)")
                do {
                    try? FileManager.default.removeItem(at: copyUrl)
                    try FileManager.default.copyItem(at: url, to: copyUrl)
                    readPath = copyUrl.path
                    tempURL = copyUrl
                } catch {
                    await MainActor.run {
                        self.isImporting = false
                        self.statusMessage = L10n.text("Unable to read file: %@", String(describing: error.localizedDescription))
                    }
                    return
                }
            }

            defer {
                if let tempURL {
                    try? FileManager.default.removeItem(at: tempURL)
                }
            }

            do {
                if matchOnly {
                    let res = try importer.matchAndFillWorks(fromDataDb: readPath)
                    await MainActor.run {
                        self.isImporting = false
                        self.statusMessage = L10n.text("Metadata matched! Filled %2$@ of %1$@ saved works.", String(describing: res.totalWorks), String(describing: res.matched))
                        self.loadStats()
                    }
                } else {
                    let total = try importer.importDataDb(path: readPath) { progress in
                        Task { @MainActor in
                            self.statusMessage = L10n.text("Importing entire catalog… (%@ records)", String(describing: progress))
                        }
                    }
                    await MainActor.run {
                        self.isImporting = false
                        self.statusMessage = L10n.text("data.db imported: %@ catalog records applied", String(describing: total))
                        self.loadStats()
                    }
                }
            } catch {
                await MainActor.run {
                    self.isImporting = false
                    self.statusMessage = L10n.text("Import failed: %@", String(describing: error.localizedDescription))
                }
            }
        }
    }

    private func exportBackup() {
        do {
            let folders = try env.database.listFolders()
            let works = try env.database.listWorks()
            let artists = try env.database.listArtists()

            let backupData: [String: Any] = [
                "version": 2,
                "exported_at": ISO8601DateFormatter().string(from: Date()),
                "folders": folders.map { [
                    "id": $0.id ?? 0,
                    "name": $0.name,
                    "color": $0.color,
                    "sort_order": $0.sortOrder,
                    "violet_group_id": $0.violetGroupId as Any
                ] },
                "works": works.map { work -> [String: Any] in
                    var dict: [String: Any] = [
                        "gallery_id": work.galleryId,
                        "title": work.title ?? "",
                        "artists": work.artists ?? "",
                        "note": work.note ?? "",
                        "bookmarked_at": work.bookmarkedAt
                    ]
                    if let lang = work.language { dict["language"] = lang }
                    if let type = work.type { dict["type"] = type }
                    if let series = work.series { dict["series"] = series }
                    if let groups = work.groups { dict["groups"] = groups }
                    if let tags = work.tags { dict["tags"] = tags }
                    if let pub = work.publishedAt { dict["published_at"] = pub }
                    if !work.folders.isEmpty {
                        dict["folders"] = work.folders.map(\.name)
                    }
                    // Only save thumb_page if user specified it and > 1
                    if let page = work.thumbPage, page > 1 {
                        dict["thumb_page"] = page
                    }
                    return dict
                },
                "artists": artists.map { [
                    "name": $0.name,
                    "kind": $0.kind,
                    "note": $0.note ?? ""
                ] }
            ]

            let jsonData = try JSONSerialization.data(withJSONObject: backupData, options: .prettyPrinted)
            let tempUrl = FileManager.default.temporaryDirectory.appendingPathComponent("number-memo-backup.json")
            try jsonData.write(to: tempUrl, options: .atomic)
            self.backupFileURL = tempUrl
            self.showShareSheet = true
        } catch {
            statusMessage = L10n.text("Unable to create backup: %@", String(describing: error.localizedDescription))
        }
    }

    private func handleBackupImport(result: Result<[URL], Error>) {
        guard case .success(let urls) = result, let url = urls.first else { return }
        isImporting = true
        statusMessage = L10n.text("Restoring backup…")

        let db = env.database
        let envRef = env

        Task.detached(priority: .userInitiated) {
            let hasAccess = url.startAccessingSecurityScopedResource()
            defer {
                if hasAccess { url.stopAccessingSecurityScopedResource() }
            }

            do {
                let data = try Data(contentsOf: url)
                guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    throw URLError(.cannotParseResponse)
                }

                var restoredWorks = 0
                var restoredFolders = 0

                // 1. Folders
                var folderNameToId: [String: Int64] = [:]
                if let rawFolders = json["folders"] as? [[String: Any]] {
                    for f in rawFolders {
                        guard let name = f["name"] as? String, !name.isEmpty else { continue }
                        let color = (f["color"] as? Int64) ?? (f["color"] as? Int).map(Int64.init) ?? 0xFF2563EB
                        let violetGroupId = (f["violet_group_id"] as? Int64) ?? (f["violet_group_id"] as? Int).map(Int64.init)
                        if let existing = try db.listFolders().first(where: { $0.name == name }) {
                            if let id = existing.id {
                                folderNameToId[name] = id
                            }
                        } else {
                            let created = try db.createFolder(
                                name: name,
                                color: color,
                                violetGroupId: violetGroupId
                            )
                            if let id = created.id {
                                folderNameToId[name] = id
                                restoredFolders += 1
                            }
                        }
                    }
                }

                // 2. Works
                if let rawWorks = json["works"] as? [[String: Any]] {
                    for w in rawWorks {
                        guard let galleryId = (w["gallery_id"] as? Int64) ?? (w["gallery_id"] as? Int).map(Int64.init) else { continue }
                        let title = w["title"] as? String
                        let artists = w["artists"] as? String
                        let note = w["note"] as? String
                        let language = w["language"] as? String
                        let type = w["type"] as? String
                        let series = w["series"] as? String
                        let groups = w["groups"] as? String
                        let tags = w["tags"] as? String
                        let publishedAt = w["published_at"] as? String
                        let bookmarkedAt = w["bookmarked_at"] as? String

                        let upserted = try db.upsertWork(
                            galleryId: galleryId,
                            title: title,
                            artists: artists,
                            language: language,
                            type: type,
                            series: series,
                            groups: groups,
                            tags: tags,
                            publishedAt: publishedAt,
                            bookmarkedAt: bookmarkedAt
                        )
                        if let note, !note.isEmpty {
                            try? db.setNote(galleryId: galleryId, note: note)
                        }

                        // Restore thumb_page if specified (> 1)
                        if let thumbPage = w["thumb_page"] as? Int, thumbPage > 1 {
                            try? db.setThumbPage(galleryId: galleryId, page: thumbPage)
                        }

                        // Folders mapping
                        if let folderNames = w["folders"] as? [String] {
                            for fn in folderNames {
                                if let fid = folderNameToId[fn] {
                                    if let wid = upserted.id {
                                        try? db.addWorkToFolder(workId: wid, folderId: fid)
                                    }
                                }
                            }
                        }
                        restoredWorks += 1
                    }
                }

                // 3. Artists
                if let rawArtists = json["artists"] as? [[String: Any]] {
                    for a in rawArtists {
                        guard let name = a["name"] as? String, !name.isEmpty else { continue }
                        let kind = (a["kind"] as? Int) ?? 0
                        _ = try? db.addFavoriteArtist(name: name, kind: kind)
                    }
                }

                await MainActor.run {
                    self.isImporting = false
                    self.statusMessage = L10n.text("Backup restored: %@ works, %@ folders", String(describing: restoredWorks), String(describing: restoredFolders))
                    self.loadStats()
                    envRef.startCoverQueue()
                }
            } catch {
                await MainActor.run {
                    self.isImporting = false
                    self.statusMessage = L10n.text("Unable to restore backup: %@", String(describing: error.localizedDescription))
                }
            }
        }
    }
}

private struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
