import SwiftUI

/// Zero means automatic. SwiftUI resolves columns from the available container width,
/// including iPad multitasking and resizable iOS-app windows on Apple silicon Macs.
enum WorkGridLayout {
    static func columns(_ count: Int) -> [GridItem] {
        if count == 0 {
            return [GridItem(.adaptive(minimum: 160), spacing: 14, alignment: .top)]
        }
        return Array(repeating: GridItem(.flexible(), spacing: 14, alignment: .top), count: min(5, max(1, count)))
    }
}

/// Shared cover ratio, language badge and typography for local and remote galleries.
struct GalleryCardLayout<Cover: View>: View {
    let title: String
    let artists: String
    let language: String
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
                if !artists.isEmpty { Text(artists).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            }.padding(.horizontal, 2)
            Spacer(minLength: 0)
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

public struct WorkCardView: View {
    public let work: Work
    public init(work: Work) { self.work = work }
    public var body: some View {
        GalleryCardLayout(title: work.hasTitle ? work.title ?? "" : String(work.galleryId), artists: work.artists ?? "", language: work.language ?? "") {
            if let path = work.thumbPath, work.thumbStatus == "ready", let image = UIImage(contentsOfFile: path) {
                Image(uiImage: image).resizable().scaledToFill().id("\(work.galleryId)_\(work.thumbPage ?? 1)")
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
