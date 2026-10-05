import SwiftUI

struct ReaderPreviewView: View {
    @Environment(\.dismiss) private var dismiss
    let gallery: NativeGallery
    let images: PageImageStore
    @Binding var current: Int
    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 3), spacing: 16) {
                        ForEach(gallery.pages.indices, id: \.self) { index in
                            Button { current = index; dismiss() } label: {
                                VStack {
                                    ReaderThumbnail(page: gallery.pages[index], galleryID: gallery.id, images: images)
                                        .aspectRatio(0.72, contentMode: .fit).clipped()
                                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(current == index ? Color.accentColor : .clear, lineWidth: 3))
                                    Text("\(index + 1)").font(.caption.monospacedDigit())
                                }
                            }.buttonStyle(.plain).id(index).accessibilityLabel(L10n.text("Pages: %@", String(describing: index + 1)))
                                .accessibilityIdentifier("reader.preview.\(index + 1)")
                        }
                    }.padding(16)
                }.onAppear { proxy.scrollTo(current, anchor: .center) }
            }
            .navigationTitle(L10n.text("Total pages: %@", String(describing: gallery.pages.count))).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(L10n.text("Done")) { dismiss() } } }
        }
    }
}

struct ReaderThumbnail: View {
    let page: GalleryPage
    let galleryID: Int64
    let images: PageImageStore
    @State private var image: UIImage?
    var body: some View {
        Color.secondary.opacity(0.1).overlay {
            if let image { Image(uiImage: image).resizable().scaledToFit() }
            else { Image(systemName: "photo").foregroundStyle(.secondary) }
        }.task(id: page.hash) { image = try? await images.load(page, galleryID: galleryID, thumbnail: true) }
    }
}

struct ReaderDetailsView: View {
    let search: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    let gallery: NativeGallery
    var body: some View {
        NavigationStack {
            List {
                Section { Text(gallery.title).font(.headline).textSelection(.enabled) }
                LabeledContent(L10n.text("Work Number"), value: String(gallery.id))
                Section(L10n.text("Artists")) {
                    FlowLayout(spacing: 8) {
                        ForEach(gallery.artists, id: \.self) { name in chip(name, query: "artist:" + name) }
                    }
                }
                Section(L10n.text("Language")) { chip(gallery.language, query: "language:" + gallery.language) }
                LabeledContent(L10n.text("Type"), value: gallery.type)
                LabeledContent(L10n.text("Page"), value: String(gallery.pages.count))
                Section(L10n.text("Tags")) {
                    FlowLayout(spacing: 8) {
                        ForEach(Array(Set(gallery.tags)).sorted(), id: \.self) { tag in chip(tag, query: tag) }
                    }
                }
            }
            .navigationTitle(L10n.text("Details")).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(L10n.text("Done")) { dismiss() } } }
        }
    }
    private func chip(_ title: String, query: String) -> some View {
        Button(title) { dismiss(); search(query.replacingOccurrences(of: " ", with: "_")) }
            .buttonStyle(.bordered).buttonBorderShape(.capsule)
    }

}
