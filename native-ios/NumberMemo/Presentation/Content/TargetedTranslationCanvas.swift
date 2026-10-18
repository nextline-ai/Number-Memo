import SwiftUI
import Translation
import NaturalLanguage

/// Apple Translation supplies the requested target; the original image remains
/// intact underneath text overlays that zoom and pan with the page.
@available(iOS 18.0, *)
struct TargetedTranslationCanvas: View {
    let image: UIImage
    let target: String
    let retry: Int
    let ready: () -> Void
    let failed: (String) -> Void
    @State private var regions: [ReaderTextRegion] = []
    @State private var translated: [ReaderTextRegion] = []
    @State private var configuration: TranslationSession.Configuration?
    var body: some View {
        TranslatedPageCanvas(image: image, regions: translated)
            .task(id: retry) {
                do {
                    regions = try await ReaderTextRecognizer.shared.recognize(image)
                    try Task.checkCancellation()
                    guard !regions.isEmpty else { failed(L10n.text("No text was found in this image.")); return }
                    let recognizer = NLLanguageRecognizer()
                    recognizer.processString(regions.map(\.text).joined(separator: "\n"))
                    if let source = recognizer.dominantLanguage,
                       Locale.Language(identifier: source.rawValue).languageCode == Locale.Language(identifier: target).languageCode {
                        translated = regions
                        ready()
                        return
                    }
                    if configuration == nil { configuration = .init(target: Locale.Language(identifier: target)) }
                    else { configuration?.invalidate() }
                } catch { if !Task.isCancelled { failed(error.localizedDescription) } }
            }
            .translationTask(configuration) { session in
                do {
                    let requests = regions.enumerated().map { TranslationSession.Request(sourceText: $0.element.text, clientIdentifier: String($0.offset)) }
                    let responses = try await session.translations(from: requests)
                    try Task.checkCancellation()
                    translated = responses.compactMap { response in
                        guard let key = response.clientIdentifier, let index = Int(key), regions.indices.contains(index) else { return nil }
                        return ReaderTextRegion(text: response.targetText, bounds: regions[index].bounds)
                    }
                    ready()
                } catch { if !Task.isCancelled { failed(error.localizedDescription) } }
            }
    }
}

private struct TranslatedPageCanvas: UIViewRepresentable {
    let image: UIImage
    let regions: [ReaderTextRegion]
    func makeUIView(context: Context) -> TranslatedPageView { TranslatedPageView() }
    func updateUIView(_ view: TranslatedPageView, context: Context) { view.configure(image, regions: regions) }
}

final class TranslatedPageView: UIView {
    private let scroll = PageScrollView()
    private var labels: [UILabel] = []
    private var regions: [ReaderTextRegion] = []
    private var image: UIImage?
    private var labelLayoutSize = CGSize.zero
    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        addSubview(scroll)
        scroll.geometryChanged = { [weak self] in self?.placeLabels() }
        scroll.imageView.accessibilityIdentifier = "reader.translation.image"
        scroll.imageView.isAccessibilityElement = false
        scroll.imageView.accessibilityCustomActions = []
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layoutSubviews() { super.layoutSubviews(); scroll.frame = bounds; placeLabels() }
    func configure(_ image: UIImage, regions: [ReaderTextRegion]) {
        if self.image !== image { self.image = image; labelLayoutSize = .zero; scroll.update(image: image) }
        guard self.regions != regions else { return }
        self.regions = regions
        labelLayoutSize = .zero
        labels.forEach { $0.removeFromSuperview() }
        labels = regions.enumerated().map { index, region in
            let label = UILabel()
            label.text = region.text
            label.textColor = .black
            label.backgroundColor = .white
            label.numberOfLines = 0
            label.textAlignment = .center
            label.adjustsFontSizeToFitWidth = true
            label.minimumScaleFactor = 0.5
            label.layer.cornerRadius = 3
            label.clipsToBounds = true
            label.accessibilityIdentifier = "reader.translation.text.\(index)"
            scroll.imageView.addSubview(label)
            return label
        }
        placeLabels()
    }
    private func placeLabels() {
        let size = scroll.imageView.bounds.size
        // Labels are children of imageView, so UIKit already transforms them with
        // the image. Pan and zoom do not change their local layout or typography.
        guard size.width > 0, size.height > 0, size != labelLayoutSize else { return }
        labelLayoutSize = size
        for (index, region) in regions.enumerated() where labels.indices.contains(index) {
            let box = region.bounds
            let frame = CGRect(x: box.minX * size.width, y: (1 - box.maxY) * size.height,
                               width: box.width * size.width, height: box.height * size.height)
            labels[index].frame = frame.insetBy(dx: -3, dy: -3).intersection(CGRect(origin: .zero, size: size))
            labels[index].font = .systemFont(ofSize: max(8, min(22, frame.height * 0.78)), weight: .medium)
        }
    }
}
