import SwiftUI
import Vision
import VisionKit
import ImageIO

struct ReaderTextRegion: Sendable {
    let text: String
    let bounds: CGRect
}

actor ReaderTextRecognizer {
    static let shared = ReaderTextRecognizer()
    func recognize(_ image: UIImage) throws -> [ReaderTextRegion] {
        try Task.checkCancellation()
        guard let cgImage = image.cgImage else { throw ContentError.unsupportedFormat }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        let supported = try request.supportedRecognitionLanguages()
        request.recognitionLanguages = ["ja-JP", "en-US", "ko-KR", "zh-Hans", "zh-Hant"].filter(supported.contains)
        try VNImageRequestHandler(cgImage: cgImage).perform([request])
        try Task.checkCancellation()
        return (request.results ?? []).compactMap { observation in
            guard let candidate = observation.topCandidates(1).first, !candidate.string.isEmpty else { return nil }
            return ReaderTextRegion(text: candidate.string, bounds: observation.boundingBox)
        }
    }
}

struct ReaderTranslationRequest: Identifiable {
    let id = UUID()
    let index: Int
    var rect = CGRect(x: 0, y: 0, width: 1, height: 1)
}

/// Use the same VisionKit image interaction as the former in-app browser.
/// Apple owns recognition, translation grouping, backgrounds and translated text layout.
struct ReaderTranslationView: View {
    let loadImage: () async throws -> UIImage
    let finished: () -> Void
    let failed: (String) -> Void
    private let targetLanguage: String
    @State private var image: UIImage?
    @State private var analyzing = true
    @State private var needsManualAction = false
    @State private var retry = 0

    init(page: GalleryPage, galleryID: Int64, images: PageImageStore, rect: CGRect, finished: @escaping () -> Void, failed: @escaping (String) -> Void) {
        self.loadImage = { try await images.translationCrop(page, galleryID: galleryID, rect: rect) }
        self.finished = finished; self.failed = failed
        self.targetLanguage = ReaderTranslationLanguage.preference(booru: false)
    }
    init(loadImage: @escaping () async throws -> UIImage, booru: Bool = false, finished: @escaping () -> Void, failed: @escaping (String) -> Void) {
        self.loadImage = loadImage; self.finished = finished; self.failed = failed
        self.targetLanguage = ReaderTranslationLanguage.preference(booru: booru)
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            if let image {
                if #available(iOS 18.0, *), targetLanguage != "system" {
                    TargetedTranslationCanvas(image: image, target: ReaderTranslationLanguage.resolved(targetLanguage), retry: retry,
                                              ready: { analyzing = false }, failed: failed).ignoresSafeArea()
                } else { LiveTextTranslationCanvas(image: image, retry: retry, ready: { automatic in
                    analyzing = false
                    needsManualAction = !automatic
                }, failed: failed).ignoresSafeArea() }
            }
            VStack(alignment: .trailing, spacing: 10) {
                Button(L10n.text("Original"), systemImage: "xmark") { finished() }
                    .buttonStyle(.borderedProminent).tint(.black.opacity(0.8))
                    .accessibilityIdentifier("reader.original")
                if analyzing {
                    ProgressView().tint(.white).padding(12).background(.black.opacity(0.75), in: Capsule())
                        .accessibilityLabel(L10n.text("Preparing Apple image translation"))
                        .accessibilityIdentifier("reader.translation.progress")
                }
                if needsManualAction {
                    Button(L10n.text("Retry Translation"), systemImage: "arrow.clockwise") {
                        analyzing = true; needsManualAction = false; retry += 1
                    }.buttonStyle(.borderedProminent).tint(.black.opacity(0.8))
                        .accessibilityIdentifier("reader.translation.retry")
                }
            }.padding(16)
        }
        .task {
            guard ImageAnalyzer.isSupported else { failed(L10n.text("This device does not support Apple image analysis.")); return }
            do {
                // Decode the original pixels, including the current enlarged viewport, without painting over them.
                image = try await loadImage()
            } catch { if !Task.isCancelled { failed(ContentError.message(error)) } }
        }
    }
}

/// VisionKit's interface is attached to a stationary container. Only the image zooms and pans.
/// Analysis is performed once per translation session; zoom never replaces it or toggles translation.
private struct LiveTextTranslationCanvas: UIViewRepresentable {
    let image: UIImage
    let retry: Int
    let ready: (Bool) -> Void
    let failed: (String) -> Void
    func makeUIView(context: Context) -> LiveTextCanvasView { LiveTextCanvasView() }
    func updateUIView(_ view: LiveTextCanvasView, context: Context) {
        view.configure(image: image, retry: retry, ready: ready, failed: failed)
    }
    static func dismantleUIView(_ view: LiveTextCanvasView, coordinator: ()) { view.cancel() }
}

final class LiveTextCanvasView: UIView, ImageAnalysisInteractionDelegate, UIGestureRecognizerDelegate {
    let scroll = PageScrollView()
    let interaction = ImageAnalysisInteraction()
    private var image: UIImage?
    private var retry = -1
    private var analysisTask: Task<Void, Never>?
    private var activationTask: Task<Void, Never>?
    private var ready: (Bool) -> Void = { _ in }
    private var analysisCount = 0
    private var pinchStartScale: CGFloat = 1
    private var pinchAnchor = CGPoint.zero
    private var panStartOffset = CGPoint.zero
    private lazy var canvasPan = UIPanGestureRecognizer(target: self, action: #selector(panned(_:)))
    private lazy var canvasPinch = UIPinchGestureRecognizer(target: self, action: #selector(pinched(_:)))

    init() {
        super.init(frame: .zero)
        backgroundColor = .black
        clipsToBounds = true
        addSubview(scroll)
        scroll.usesExternalGestures = true
        scroll.pinchGestureRecognizer?.isEnabled = false
        for gesture in scroll.gestureRecognizers ?? [] {
            if gesture is UILongPressGestureRecognizer || (gesture as? UITapGestureRecognizer)?.numberOfTapsRequired == 1 {
                scroll.removeGestureRecognizer(gesture)
            } else if let doubleTap = gesture as? UITapGestureRecognizer {
                // VisionKit draws above the image. Put double tap on their common ancestor.
                scroll.removeGestureRecognizer(doubleTap)
                doubleTap.delegate = self
                addGestureRecognizer(doubleTap)
            }
        }
        canvasPan.maximumNumberOfTouches = 1
        canvasPan.delegate = self
        canvasPinch.delegate = self
        addGestureRecognizer(canvasPan)
        addGestureRecognizer(canvasPinch)
        scroll.imageView.accessibilityIdentifier = "reader.translation.image"
        scroll.imageView.isAccessibilityElement = false
        interaction.delegate = self
        interaction.preferredInteractionTypes = [.textSelection, .automatic]
        addInteraction(interaction)
        scroll.geometryChanged = { [weak self] in self?.updateInterfaceGeometry() }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layoutSubviews() {
        super.layoutSubviews()
        scroll.frame = bounds
        updateInterfaceGeometry()
    }
    private func updateInterfaceGeometry() {
        let insets = UIEdgeInsets(top: safeAreaInsets.top + 8, left: 12, bottom: safeAreaInsets.bottom + 12, right: 12)
        if interaction.supplementaryInterfaceContentInsets != insets { interaction.supplementaryInterfaceContentInsets = insets }
        interaction.setContentsRectNeedsUpdate()
    }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        var node = touch.view
        while let current = node, current !== self {
            if current is UIControl { return false }
            node = current.superview
        }
        return true
    }
    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        gestureRecognizer !== canvasPan || (scroll.zoomScale > 1.01 && !interaction.hasActiveTextSelection)
    }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        gestureRecognizer === canvasPinch || other === canvasPinch
    }
    @objc private func panned(_ gesture: UIPanGestureRecognizer) {
        if gesture.state == .began { panStartOffset = scroll.contentOffset }
        let delta = gesture.translation(in: self)
        if gesture.state == .began || gesture.state == .changed {
            moveImage(to: CGPoint(x: panStartOffset.x - delta.x, y: panStartOffset.y - delta.y))
        }
    }
    @objc private func pinched(_ gesture: UIPinchGestureRecognizer) {
        if gesture.state == .began {
            pinchStartScale = scroll.zoomScale
            pinchAnchor = gesture.location(in: scroll.imageView)
        }
        if gesture.state == .began || gesture.state == .changed {
            let scale = min(scroll.maximumZoomScale, max(1, pinchStartScale * gesture.scale))
            let point = gesture.location(in: self)
            scroll.setZoomScale(scale, animated: false)
            moveImage(to: CGPoint(x: pinchAnchor.x * scale - point.x, y: pinchAnchor.y * scale - point.y))
        }
        if gesture.state == .ended || gesture.state == .cancelled, scroll.zoomScale <= 1.01 {
            moveImage(to: CGPoint(x: -scroll.contentInset.left, y: -scroll.contentInset.top))
        }
    }
    private func moveImage(to offset: CGPoint) {
        let inset = scroll.contentInset
        scroll.setContentOffset(CGPoint(x: min(max(-inset.left, offset.x), max(-inset.left, scroll.contentSize.width - scroll.bounds.width + inset.right)),
                                        y: min(max(-inset.top, offset.y), max(-inset.top, scroll.contentSize.height - scroll.bounds.height + inset.bottom))), animated: false)
    }
    func contentView(for interaction: ImageAnalysisInteraction) -> UIView? { scroll.imageView }
    func contentsRect(for interaction: ImageAnalysisInteraction) -> CGRect {
        guard bounds.width > 0, bounds.height > 0 else { return .zero }
        let frame = scroll.imageView.convert(scroll.imageView.bounds, to: self)
        return CGRect(x: frame.minX / bounds.width, y: frame.minY / bounds.height,
                      width: frame.width / bounds.width, height: frame.height / bounds.height)
    }
    func configure(image: UIImage, retry: Int, ready: @escaping (Bool) -> Void, failed: @escaping (String) -> Void) {
        self.ready = ready
        if self.image === image {
            if self.retry != retry { self.retry = retry; startTranslation() }
            return
        }
        cancel()
        self.image = image
        self.retry = retry
        scroll.update(image: image)
        analysisTask = Task { [weak self] in
            do {
                // Automatic language detection supports mixed-language pages without a fixed locale priority.
                let analysis = try await ImageAnalyzer().analyze(image, configuration: .init([.text]))
                try Task.checkCancellation()
                guard let self else { return }
                guard !analysis.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    failed(L10n.text("No text to translate was found in this area.")); return
                }
                #if DEBUG
                if ContentUITestSupport.enabled {
                    analysisCount += 1
                    accessibilityIdentifier = "reader.translation.canvas"
                    accessibilityValue = L10n.text("Analyses: %@", String(describing: analysisCount))
                }
                #endif
                interaction.analysis = analysis
                interaction.selectableItemsHighlighted = true
                startTranslation()
            } catch { if !Task.isCancelled { failed(ContentError.message(error)) } }
        }
    }
    private func startTranslation() {
        guard interaction.analysis != nil else { return }
        activationTask?.cancel()
        activationTask = Task { [weak self] in
            // System controls may appear later than the OCR result. Wait for an enabled action,
            // invoke it only once, and never search outside this translation canvas.
            for _ in 0..<60 {
                do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
                guard let self else { return }
                guard window != nil, bounds.width > 0 else { continue }
                layoutIfNeeded()
                if ReaderLiveTextAction.activate(in: self) { ready(true); return }
            }
            self?.ready(false)
        }
    }
    func cancel() {
        analysisTask?.cancel(); activationTask?.cancel()
        interaction.analysis = nil
    }
}

@MainActor enum ReaderLiveTextAction {
    static func activate(in view: UIView) -> Bool {
        // Menu actions are more reliable than the transient visual shortcut button.
        if activateMenu(in: view) { return true }
        return activateControl(in: view)
    }
    private static func activateMenu(in view: UIView) -> Bool {
        for child in view.subviews where !child.isHidden && child.alpha > 0.01 {
            if let button = child as? UIButton, button.isEnabled,
               let menu = button.menu, perform(in: menu, sender: button) { return true }
            if activateMenu(in: child) { return true }
        }
        return false
    }
    private static func activateControl(in view: UIView) -> Bool {
        for child in view.subviews where !child.isHidden && child.alpha > 0.01 {
            if let control = child as? UIControl, control.isEnabled,
               matches((control as? UIButton)?.title(for: .normal)) || matches(control.accessibilityLabel) || matches(control.accessibilityIdentifier) {
                // A selected shortcut already represents translation; pressing it again would turn it off.
                if control.isSelected { return true }
                let events = control.allControlEvents
                if events.contains(.primaryActionTriggered) {
                    control.sendActions(for: .primaryActionTriggered)
                    return true
                }
                if events.contains(.touchUpInside) {
                    control.sendActions(for: .touchUpInside)
                    return true
                }
                // A visible shortcut can precede registration of its action. Keep waiting in that case.
            }
            if activateControl(in: child) { return true }
        }
        return false
    }
    private static func matches(_ title: String?) -> Bool {
        guard let title else { return false }
        return ["translate", "번역", "翻訳", "翻译", "翻譯"].contains { title.localizedCaseInsensitiveContains($0) }
    }
    private static func perform(in menu: UIMenu, sender: UIButton) -> Bool {
        for element in menu.children {
            if let action = element as? UIAction, matches(action.title),
               !action.attributes.contains(.disabled), !action.attributes.contains(.hidden) {
                if action.state != .on { action.performWithSender(sender, target: nil) }
                return true
            }
            if let submenu = element as? UIMenu, perform(in: submenu, sender: sender) { return true }
        }
        return false
    }
}

/// Shared bounded decoding and viewport crop for both Hitomi and Booru translation.
enum ReaderTranslationImage {
    static func decode(source: CGImageSource, rect: CGRect) throws -> UIImage {
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 6000,
            kCGImageSourceShouldCacheImmediately: true
        ] as CFDictionary) else { throw ContentError.unsupportedFormat }
        let unit = CGRect(x: 0, y: 0, width: 1, height: 1)
        let bounded = rect.intersection(unit)
        guard !bounded.isNull, !bounded.isEmpty else { throw ContentError.invalidResponse }
        let region = CGRect(x: bounded.minX * CGFloat(image.width), y: bounded.minY * CGFloat(image.height),
                            width: bounded.width * CGFloat(image.width), height: bounded.height * CGFloat(image.height)).integral
        guard let crop = image.cropping(to: region) else { throw ContentError.invalidResponse }
        return UIImage(cgImage: crop)
    }
}
