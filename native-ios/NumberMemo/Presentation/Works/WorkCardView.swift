import SwiftUI
import Combine

/// Zero means automatic. SwiftUI resolves columns from the available container width,
/// including iPad multitasking and resizable iOS-app windows on Apple silicon Macs.
enum WorkGridLayout {
    static func columns(_ count: Int, minimum: CGFloat = 160) -> [GridItem] {
        if count == 0 {
            return [GridItem(.adaptive(minimum: minimum), spacing: 14, alignment: .top)]
        }
        return Array(repeating: GridItem(.flexible(), spacing: 14, alignment: .top), count: min(5, max(1, count)))
    }
}

/// Shared cover ratio, language badge and typography for local and remote galleries.
struct GalleryCardLayout<Cover: View>: View {
    let title: String
    let artists: String
    let language: String
    var recommendationTag: String? = nil
    @ViewBuilder let cover: () -> Cover
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .bottomTrailing) {
                Color.clear.aspectRatio(0.72, contentMode: .fit).overlay { cover() }.clipped()
                if !language.isEmpty {
                    Text(language).font(.caption2.bold()).padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.ultraThinMaterial, in: Capsule()).padding(6)
                }
            }.clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.medium)).lineLimit(2).multilineTextAlignment(.leading).foregroundStyle(.primary)
                if let recommendationTag {
                    Label(recommendationTag, systemImage: "number").font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                if !artists.isEmpty { Text(artists).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            }.padding(.horizontal, 2)
        }.frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

public struct WorkCardView: View {
    public let work: Work
    public init(work: Work) { self.work = work }
    public var body: some View {
        GalleryCardLayout(title: work.hasTitle ? work.title ?? "" : String(work.galleryId), artists: work.artists ?? "", language: work.language ?? "") {
            LocalThumbnailView(path: work.thumbStatus == "ready" ? work.thumbPath : nil, revision: String(work.thumbPage ?? 1)) { image in
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    Rectangle().fill(Color.secondary.opacity(0.12)).overlay {
                        VStack(spacing: 6) {
                            Image(systemName: work.thumbStatus == "gone" ? "slash.circle" : "photo").font(.title2)
                            Text(String(work.galleryId)).font(.caption2.monospacedDigit())
                        }.foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

/// Only visible cells request local files, with cancellation preventing stale
/// results from being assigned when SwiftUI reuses or removes a cell.
struct LocalThumbnailView<Content: View>: View {
    let path: String?
    var revision: String = ""
    @ViewBuilder let content: (UIImage?) -> Content
    @State private var image: UIImage?
    @State private var loadedRequest: Request?
    @State private var cacheRevision = 0

    private struct Request: Equatable {
        let path: String?
        let revision: String
        let cacheRevision: Int
    }

    var body: some View {
        let request = Request(path: path, revision: revision, cacheRevision: cacheRevision)
        content(loadedRequest == request ? image : path.flatMap { LocalThumbnailCache.shared.image(forPath: $0) })
            .task(id: request) {
                guard let path else { image = nil; loadedRequest = request; return }
                let loadedImage = await LocalThumbnailCache.shared.load(forPath: path)
                guard !Task.isCancelled else { return }
                image = loadedImage
                loadedRequest = request
            }
            .onReceive(NotificationCenter.default.publisher(for: LocalThumbnailCache.didInvalidate).receive(on: DispatchQueue.main)) { notification in
                guard (notification.object as? LocalThumbnailCache) === LocalThumbnailCache.shared else { return }
                guard notification.userInfo?["path"] == nil || notification.userInfo?["path"] as? String == path else { return }
                cacheRevision += 1
            }
    }
}
