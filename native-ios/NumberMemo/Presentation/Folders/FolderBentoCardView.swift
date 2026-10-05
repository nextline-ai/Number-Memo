import SwiftUI

public struct FolderBentoCardView: View {
    public let folder: Folder
    public let previews: [Work]
    public let onChangeColor: (() -> Void)?

    public init(folder: Folder, previews: [Work] = [], onChangeColor: (() -> Void)? = nil) {
        self.folder = folder
        self.previews = previews
        self.onChangeColor = onChangeColor
    }

    private var folderColor: Color {
        Color(argb: folder.color)
    }

    /// Determines white or black text depending on background luminance
    private var textColor: Color {
        let r = Double((folder.color >> 16) & 0xFF) / 255.0
        let g = Double((folder.color >> 8) & 0xFF) / 255.0
        let b = Double(folder.color & 0xFF) / 255.0
        let luminance = 0.2126 * r + 0.7152 * g + 0.0722 * b
        return luminance > 0.48 ? Color.black : Color.white
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Top: 2x2 thumbnails preview
            Color.clear.aspectRatio(1.25, contentMode: .fit).overlay {
                VStack(spacing: 4) {
                    HStack(spacing: 4) {
                        thumbCell(index: 0)
                        thumbCell(index: 1)
                    }
                    HStack(spacing: 4) {
                        thumbCell(index: 2)
                        thumbCell(index: 3)
                    }
                }
                .padding(6)
                .frame(maxWidth: .infinity)
            }
            .clipped()

            // Bottom: Folder title & count
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(folder.displayName)
                        .font(.subheadline.bold())
                        .lineLimit(1)
                        .foregroundColor(textColor)

                    Text(L10n.text("%@ items", String(describing: folder.workCount)))
                        .font(.caption2.weight(.semibold))
                        .foregroundColor(textColor.opacity(0.85))
                }

                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
        .background(folderColor)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.white.opacity(0.15), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.1), radius: 8, y: 3)
    }

    @ViewBuilder
    private func thumbCell(index: Int) -> some View {
        Color.clear
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(
                Group {
                    if index < previews.count {
                        let work = previews[index]
                        if let path = work.thumbPath,
                           work.thumbStatus == "ready",
                           let uiImage = UIImage(contentsOfFile: path) {
                            Image(uiImage: uiImage)
                                .resizable()
                                .scaledToFill()
                                .id("\(work.galleryId)_\(work.thumbPage ?? 1)")
                        } else {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(textColor.opacity(0.14))
                                .overlay(
                                    Text(verbatim: String(work.galleryId))
                                        .font(.system(size: 10, weight: .semibold))
                                        .foregroundColor(textColor.opacity(0.85))
                                        .lineLimit(1)
                                        .padding(2)
                                )
                        }
                    } else {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(textColor.opacity(0.08))
                    }
                }
            )
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}
