import SwiftUI

public struct WorkDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppEnvironment.self) private var env

    public let galleryId: Int64

    @State private var work: Work?
    @State private var title: String = ""
    @State private var note: String = ""
    @State private var favoriteArtists = Set<String>()
    @State private var showBrowser = false
    @State private var toastMessage: String?
    @State private var isRefetching = false
    @State private var selectedThumbPage: Int = 1
    @State private var totalPages: Int?
    @State private var galleryHashes: [String] = []
    @State private var isChangingThumb = false
    @State private var imageReloadKey = UUID()
    @State private var showDeleteConfirmation = false

    public init(galleryId: Int64) {
        self.galleryId = galleryId
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let work {
                    WorkDetailCover(image: savedCover, loading: isChangingThumb)
                        .id(imageReloadKey)

                    // Title section
                    VStack(alignment: .leading, spacing: 6) {
                        Text(L10n.text("Title"))
                            .font(.caption.bold())
                            .foregroundColor(.secondary)
                        TextField(L10n.text("Enter a title"), text: $title)
                            .font(.headline)
                            .padding(12)
                            .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
                            .onSubmit {
                                saveTitle()
                            }
                    }

                    // Artists Section
                    if let artists = work.artists, !artists.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(L10n.text("Artists"))
                                .font(.caption.bold())
                                .foregroundColor(.secondary)
                            FlowLayout(spacing: 8) {
                                ForEach(artists.components(separatedBy: ", "), id: \.self) { artist in
                                    let isFav = favoriteArtists.contains(artist)
                                    Button {
                                        toggleFavorite(artist)
                                    } label: {
                                        HStack(spacing: 4) {
                                            Image(systemName: isFav ? "star.fill" : "star")
                                                .foregroundColor(isFav ? .yellow : .secondary)
                                            Text(artist)
                                                .foregroundColor(.primary)
                                        }
                                        .font(.subheadline)
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 6)
                                        .background(Color.secondary.opacity(0.12), in: Capsule())
                                    }
                                }
                            }
                        }
                    }

                    // Metadata badges (Language, Type, Date)
                    HStack(spacing: 12) {
                        if let lang = work.language, !lang.isEmpty {
                            Label(lang, systemImage: "character.bubble")
                                .font(.caption)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(Color.secondary.opacity(0.12), in: Capsule())
                        }
                        if let type = work.type, !type.isEmpty {
                            Label(type, systemImage: "doc")
                                .font(.caption)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(Color.secondary.opacity(0.12), in: Capsule())
                        }
                        if let published = work.publishedAt, !published.isEmpty {
                            Label(published, systemImage: "calendar")
                                .font(.caption)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(Color.secondary.opacity(0.12), in: Capsule())
                        }
                    }

                    // Tags Section
                    if let tags = work.tags, !tags.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(L10n.text("Tags (Tap to Copy)"))
                                .font(.caption.bold())
                                .foregroundColor(.secondary)
                            FlowLayout(spacing: 8) {
                                ForEach(tags.components(separatedBy: ", "), id: \.self) { tag in
                                    Button {
                                        UIPasteboard.general.string = tag
                                        showToast(L10n.text("Copied tag '%@'", String(describing: tag)))
                                    } label: {
                                        Text(tag)
                                            .font(.caption)
                                            .foregroundColor(.primary)
                                            .padding(.horizontal, 10)
                                            .padding(.vertical, 5)
                                            .background(Color.secondary.opacity(0.1), in: Capsule())
                                    }
                                }
                            }
                        }
                    }

                    // Folders
                    if !work.folders.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(L10n.text("Library Folders"))
                                .font(.caption.bold())
                                .foregroundColor(.secondary)
                            HStack {
                                ForEach(work.folders) { folder in
                                    Text(folder.displayName)
                                        .font(.caption)
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 5)
                                        .background(Color.blue.opacity(0.15), in: Capsule())
                                }
                            }
                        }
                    }

                    // Note Section
                    VStack(alignment: .leading, spacing: 6) {
                        Text(L10n.text("Notes"))
                            .font(.caption.bold())
                            .foregroundColor(.secondary)
                        TextEditor(text: $note)
                            .frame(minHeight: 90)
                            .padding(8)
                            .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
                            .onChange(of: note) { _, newValue in
                                try? env.database.setNote(galleryId: galleryId, note: newValue)
                            }
                    }

                    NavigationLink {
                        ContentReportView(page: URL(string: HitomiUrls.galleryUrl(for: galleryId))!)
                    } label: { Label(L10n.text("Report Content"), systemImage: "flag") }

                    // Action Buttons
                    VStack(spacing: 12) {
                        Button {
                            try? env.database.markOpened(galleryId: galleryId)
                            showBrowser = true
                        } label: {
                            HStack {
                                Image(systemName: "book.pages")
                                Text(L10n.text("Read"))
                            }
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .foregroundColor(.white)
                            .background(Color.blue, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        }

                        Button {
                            refetchMetadata()
                        } label: {
                            HStack {
                                if isRefetching {
                                    ProgressView().tint(.primary)
                                } else {
                                    Image(systemName: "arrow.clockwise")
                                }
                                Text(L10n.text("Refresh Cover and Title"))
                            }
                            .font(.subheadline.bold())
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .glassSurface(cornerRadius: 14, isInteractive: true)
                        }
                        .disabled(isRefetching)
                    }
                    .padding(.top, 8)

                    // Thumbnail Page Setting (Bottom)
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Label(L10n.text("Choose Thumbnail Page"), systemImage: "photo.stack")
                                .font(.caption.bold())
                                .foregroundColor(.secondary)
                            Spacer()
                            if let total = totalPages {
                                Text(L10n.text("Page %@ / %@", String(describing: selectedThumbPage), String(describing: total)))
                                    .font(.caption.monospacedDigit().bold())
                                    .foregroundColor(.secondary)
                            } else {
                                Text(L10n.text("Page %@", String(describing: selectedThumbPage)))
                                    .font(.caption.monospacedDigit().bold())
                                    .foregroundColor(.secondary)
                            }
                        }

                        HStack(spacing: 12) {
                            Stepper(
                                value: $selectedThumbPage,
                                in: 1...(totalPages ?? 999),
                                step: 1
                            ) {
                                Text(L10n.text("Page %@", String(describing: selectedThumbPage)))
                                    .font(.subheadline.bold())
                            }

                            Button {
                                applyThumbnailPage(page: selectedThumbPage)
                            } label: {
                                HStack(spacing: 4) {
                                    if isChangingThumb {
                                        ProgressView()
                                            .controlSize(.small)
                                    } else {
                                        Image(systemName: "checkmark")
                                        Text(L10n.text("Apply"))
                                    }
                                }
                                .font(.subheadline.bold())
                                .padding(.horizontal, 14)
                                .padding(.vertical, 7)
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(isChangingThumb || (selectedThumbPage == (work.thumbPage ?? 1) && work.thumbStatus == "ready"))
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                    }
                    .padding(.top, 4)
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity, minHeight: 200)
                }
            }
            .padding(16)
        }
        .navigationTitle(String(galleryId))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                HStack(spacing: 14) {
                    Button {
                        UIPasteboard.general.string = String(galleryId)
                        showToast(L10n.text("Copied work number %@", String(describing: String(galleryId))))
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }

                    Button(role: .destructive) {
                        showDeleteConfirmation = true
                    } label: {
                        Image(systemName: "trash")
                            .foregroundColor(.red)
                    }
                }
            }
        }
        .alert(L10n.text("Delete Work"), isPresented: $showDeleteConfirmation) {
            Button(L10n.text("Delete"), role: .destructive) {
                deleteWork()
            }
            Button(L10n.text("Cancel"), role: .cancel) {}
        } message: {
            Text(L10n.text("Delete this work (number: %@)?", String(describing: String(galleryId))))
        }
        .overlay(alignment: .bottom) {
            if let toastMessage {
                Text(toastMessage)
                    .font(.subheadline.bold())
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.ultraThinMaterial, in: Capsule())
                    .shadow(radius: 6)
                    .padding(.bottom, 24)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .fullScreenCover(isPresented: $showBrowser) {
            ContentEntryView(initialUrl: "https://hitomi.la/reader/\(galleryId).html#1")
        }
        .presentationDetents([.large]).presentationDragIndicator(.visible)
        .task {
            loadData()
            loadGalleryFilesIfNeeded()
        }
    }

    private var savedCover: UIImage? {
        guard let work, work.thumbStatus == "ready", let path = work.thumbPath else { return nil }
        return UIImage(contentsOfFile: path)
    }

    private func loadData() {
        if let w = try? env.database.getWork(galleryId: galleryId) {
            self.work = w
            self.title = w.title ?? ""
            self.note = w.note ?? ""
            self.selectedThumbPage = w.thumbPage ?? 1
        }
        if let artists = try? env.database.listArtists() {
            self.favoriteArtists = Set(artists.map(\.name))
        }
    }

    private func loadGalleryFilesIfNeeded() {
        guard env.isSiteVerified, galleryHashes.isEmpty else { return }
        Task {
            if let hashes = try? await HitomiAPIClient.fetchGalleryFiles(galleryId: galleryId) {
                await MainActor.run {
                    self.galleryHashes = hashes
                    self.totalPages = hashes.count
                    if self.selectedThumbPage > hashes.count {
                        self.selectedThumbPage = min(self.selectedThumbPage, max(1, hashes.count))
                    }
                }
            }
        }
    }

    private func applyThumbnailPage(page: Int) {
        guard env.isSiteVerified, !isChangingThumb else { return }
        isChangingThumb = true

        Task {
            do {
                var hashes = galleryHashes
                if hashes.isEmpty {
                    hashes = try await HitomiAPIClient.fetchGalleryFiles(galleryId: galleryId)
                    let h = hashes
                    await MainActor.run {
                        self.galleryHashes = h
                        self.totalPages = h.count
                    }
                }

                guard page >= 1, page <= hashes.count else {
                    await MainActor.run {
                        isChangingThumb = false
                        showToast(L10n.text("Invalid page number (%@ pages in total)", String(describing: hashes.count)))
                    }
                    return
                }

                let targetHash = hashes[page - 1]
                let thumbsDir = AppStorage.thumbsDirURL
                let savedFile = try await HitomiAPIClient.downloadCover(
                    galleryId: galleryId,
                    hash: targetHash,
                    destinationDir: thumbsDir
                )

                try env.database.setThumb(galleryId: galleryId, status: "ready", path: savedFile.path, page: page)

                await MainActor.run {
                    self.imageReloadKey = UUID()
                    loadData()
                    isChangingThumb = false
                    showToast(L10n.text("Page %@ set as thumbnail", String(describing: page)))
                }
            } catch {
                await MainActor.run {
                    isChangingThumb = false
                    showToast(L10n.text("Unable to change thumbnail: %@", String(describing: error.localizedDescription)))
                }
            }
        }
    }

    private func saveTitle() {
        try? env.database.setManualTitle(galleryId: galleryId, title: title)
        showToast(L10n.text("Title saved"))
    }

    private func toggleFavorite(_ name: String) {
        if favoriteArtists.contains(name) {
            try? env.database.removeFavoriteArtist(name: name)
            favoriteArtists.remove(name)
            showToast(L10n.text("Removed from Artists"))
        } else {
            _ = try? env.database.addFavoriteArtist(name: name)
            favoriteArtists.insert(name)
            showToast(L10n.text("Added to Artists"))
        }
    }

    private func refetchMetadata() {
        guard env.isSiteVerified else { showBrowser = true; return }
        isRefetching = true
        Task {
            do {
                try await env.coverQueueActor.fetchOne(galleryId)
                await MainActor.run {
                    self.imageReloadKey = UUID()
                    loadData()
                    isRefetching = false
                    showToast(L10n.text("Latest information loaded"))
                }
            } catch {
                await MainActor.run {
                    isRefetching = false
                    showToast(L10n.text("Refresh failed: %@", String(describing: error.localizedDescription)))
                }
            }
        }
    }

    private func deleteWork() {
        try? env.database.deleteWork(galleryId: galleryId)
        dismiss()
    }

    private func showToast(_ msg: String) {
        withAnimation {
            toastMessage = msg
        }
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            withAnimation {
                if toastMessage == msg {
                    toastMessage = nil
                }
            }
        }
    }
}

/// Helper for wrapping flow layout tags
public struct FlowLayout: Layout {
    public var spacing: CGFloat

    public init(spacing: CGFloat = 8) {
        self.spacing = spacing
    }

    public func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var currentX: CGFloat = 0
        var currentY: CGFloat = 0
        var lineHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if currentX + size.width > width && currentX > 0 {
                currentX = 0
                currentY += lineHeight + spacing
                lineHeight = 0
            }
            currentX += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }

        return CGSize(width: width, height: currentY + lineHeight)
    }

    public func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var currentX = bounds.minX
        var currentY = bounds.minY
        var lineHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if currentX + size.width > bounds.maxX && currentX > bounds.minX {
                currentX = bounds.minX
                currentY += lineHeight + spacing
                lineHeight = 0
            }
            subview.place(at: CGPoint(x: currentX, y: currentY), proposal: ProposedViewSize(size))
            currentX += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}


/// Reserves the thumbnail slot even during loading/failure, so actions never move under a finger.
struct WorkDetailCover: View {
    let image: UIImage?
    var loading = false
    var body: some View {
        RoundedRectangle(cornerRadius: 16).fill(Color(uiColor: .secondarySystemBackground))
            .frame(height: 300)
            .overlay {
                if let image {
                    Image(uiImage: image).resizable().scaledToFit().padding(8)
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "book.closed").font(.largeTitle).foregroundStyle(.tertiary)
                        if loading { ProgressView() }
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(L10n.text("Thumbnail"))
            .accessibilityValue(L10n.text(image == nil ? (loading ? "Loading" : "Thumbnail unavailable") : "Thumbnail loaded"))
            .accessibilityIdentifier("content.detail.cover")
    }
}
