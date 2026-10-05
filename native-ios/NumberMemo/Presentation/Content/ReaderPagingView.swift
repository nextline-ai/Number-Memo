import SwiftUI

struct ReaderPageView: View {
    let page: GalleryPage
    let galleryID: Int64
    let images: PageImageStore
    let tap: (CGFloat) -> Void
    let bookmark: () -> Void
    var viewport: (CGRect, CGFloat) -> Void = { _, _ in }
    var bookmarkRange: ClosedRange<CGFloat> = 0.3...0.7
    @State private var image: UIImage?
    @State private var error: String?
    @State private var retry = 0

    var body: some View {
        Group {
            if let shown = image {
                ZoomablePageView(image: shown, tap: tap, bookmark: bookmark, viewport: viewport, bookmarkRange: bookmarkRange)
            } else {
                GeometryReader { geometry in
                    Group {
                        if let error { ContentFailureView(message: error) { retry += 1 }.preferredColorScheme(.dark) }
                        else { ProgressView().tint(.white) }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .onTapGesture(coordinateSpace: .local) { point in tap(point.x / max(1, geometry.size.width)) }
                    .accessibilityAction(named: L10n.text("Quick Menu")) { tap(0.5) }
                }
            }
        }
        .background(.black)
        .task(id: "\(page.hash):\(retry)") {
            error = nil
            do { image = try await images.load(page, galleryID: galleryID) }
            catch { if !Task.isCancelled { self.error = ContentError.message(error) } }
        }
    }
}

struct ZoomablePageView: UIViewRepresentable {
    let image: UIImage
    let tap: (CGFloat) -> Void
    let bookmark: () -> Void
    var viewport: (CGRect, CGFloat) -> Void = { _, _ in }
    var bookmarkRange: ClosedRange<CGFloat> = 0.3...0.7
    func makeUIView(context: Context) -> PageScrollView { PageScrollView() }
    func updateUIView(_ view: PageScrollView, context: Context) {
        view.tap = tap
        view.bookmark = bookmark
        view.viewport = viewport
        view.bookmarkRange = bookmarkRange
        view.update(image: image)
    }
}

final class PageScrollView: UIScrollView, UIScrollViewDelegate {
    let imageView = UIImageView()
    var tap: (CGFloat) -> Void = { _ in }
    var bookmark: () -> Void = {}
    var viewport: (CGRect, CGFloat) -> Void = { _, _ in }
    var bookmarkRange: ClosedRange<CGFloat> = 0.3...0.7
    private var previousSize = CGSize.zero
    var geometryChanged: () -> Void = {}
    var usesExternalGestures = false
    private var lockedScrollViews: [ObjectIdentifier] = []
    private struct ParentScrollLock {
        weak var view: UIScrollView?
        let wasEnabled: Bool
        var owners: Set<ObjectIdentifier>
    }
    private static var parentLocks: [ObjectIdentifier: ParentScrollLock] = [:]

    override func didMoveToWindow() {
        super.didMoveToWindow()
        updateAncestorScrolling(lock: window != nil && zoomScale > 1.01)
    }
    private func updateAncestorScrolling(lock: Bool) {
        let owner = ObjectIdentifier(self)
        if lock {
            guard lockedScrollViews.isEmpty else { return }
            Self.parentLocks = Self.parentLocks.filter { $0.value.view != nil }
            var ancestor = superview
            while let current = ancestor {
                if let scroll = current as? UIScrollView {
                    let key = ObjectIdentifier(scroll)
                    var entry = Self.parentLocks[key] ?? ParentScrollLock(view: scroll, wasEnabled: scroll.isScrollEnabled, owners: [])
                    entry.owners.insert(owner)
                    Self.parentLocks[key] = entry
                    lockedScrollViews.append(key)
                    scroll.isScrollEnabled = false
                }
                ancestor = current.superview
            }
        } else {
            for key in lockedScrollViews {
                guard var entry = Self.parentLocks[key] else { continue }
                entry.owners.remove(owner)
                if entry.owners.isEmpty {
                    entry.view?.isScrollEnabled = entry.wasEnabled
                    Self.parentLocks.removeValue(forKey: key)
                } else { Self.parentLocks[key] = entry }
            }
            lockedScrollViews.removeAll()
        }
    }

    init() {
        super.init(frame: .zero)
        backgroundColor = .black
        delegate = self
        minimumZoomScale = 1
        maximumZoomScale = 5
        showsVerticalScrollIndicator = false
        showsHorizontalScrollIndicator = false
        contentInsetAdjustmentBehavior = .never
        imageView.contentMode = .scaleAspectFit
        imageView.isUserInteractionEnabled = true
        imageView.accessibilityIdentifier = "reader.image"
        imageView.accessibilityLabel = L10n.text("Page image")
        imageView.isAccessibilityElement = true
        addSubview(imageView)
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(doubleTapped(_:)))
        doubleTap.numberOfTapsRequired = 2
        let singleTap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
        singleTap.require(toFail: doubleTap)
        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(held(_:)))
        longPress.minimumPressDuration = 0.55
        singleTap.require(toFail: longPress)
        addGestureRecognizer(singleTap)
        addGestureRecognizer(doubleTap)
        addGestureRecognizer(longPress)
        panGestureRecognizer.isEnabled = false
        imageView.accessibilityCustomActions = [
            UIAccessibilityCustomAction(name: L10n.text("Quick Menu"), target: self, selector: #selector(accessibleMenu)),
            UIAccessibilityCustomAction(name: L10n.text("Bookmark"), target: self, selector: #selector(accessibleBookmark)),
            UIAccessibilityCustomAction(name: L10n.text("Tap Right"), target: self, selector: #selector(accessibleNext)),
            UIAccessibilityCustomAction(name: L10n.text("Tap Left"), target: self, selector: #selector(accessiblePrevious))
        ]
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func accessibleMenu() -> Bool { reportViewport(); tap(0.5); return true }
    @objc private func accessibleBookmark() -> Bool { bookmark(); return true }
    @objc private func accessibleNext() -> Bool { tap(0.9); return true }
    @objc private func accessiblePrevious() -> Bool { tap(0.1); return true }

    func update(image: UIImage) {
        guard imageView.image !== image else { return }
        let first = imageView.image == nil
        imageView.image = image
        if first { previousSize = .zero; setZoomScale(1, animated: false) }
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if bounds.size != previousSize, bounds.width > 0, bounds.height > 0, let image = imageView.image {
            previousSize = bounds.size
            setZoomScale(1, animated: false)
            let scale = min(bounds.width / image.size.width, bounds.height / image.size.height)
            let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
            imageView.frame = CGRect(origin: .zero, size: size)
            contentSize = size
            centerImage()
            setContentOffset(CGPoint(x: -contentInset.left, y: -contentInset.top), animated: false)
            DispatchQueue.main.async { [weak self] in self?.reportViewport() }
        }
        geometryChanged()
    }
    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }
    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        panGestureRecognizer.isEnabled = !usesExternalGestures && zoomScale > 1.01
        centerImage()
        updateAncestorScrolling(lock: zoomScale > 1.01)
        geometryChanged()
    }
    func scrollViewDidScroll(_ scrollView: UIScrollView) { geometryChanged() }
    func scrollViewWillBeginZooming(_ scrollView: UIScrollView, with view: UIView?) { viewport(.zero, 2) }
    func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
        if scale <= 1.01 { setContentOffset(CGPoint(x: -contentInset.left, y: -contentInset.top), animated: false) }
        reportViewport()
    }
    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) { if !decelerate { reportViewport() } }
    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) { reportViewport() }
    private func reportViewport() {
        let visible = convert(bounds, to: imageView).intersection(imageView.bounds)
        guard imageView.bounds.width > 0, imageView.bounds.height > 0, !visible.isNull else { return }
        viewport(CGRect(x: visible.minX / imageView.bounds.width, y: visible.minY / imageView.bounds.height,
                        width: visible.width / imageView.bounds.width, height: visible.height / imageView.bounds.height), zoomScale)
    }
    private func centerImage() {
        // Half a viewport of real scrollable space lets every image edge reach the screen center.
        // Symmetric insets also work for short landscape pages, where vertical movement used to vanish.
        let vertical = zoomScale > 1.01 ? bounds.height / 2 : max(0, (bounds.height - contentSize.height) / 2)
        let horizontal = zoomScale > 1.01 ? bounds.width / 2 : max(0, (bounds.width - contentSize.width) / 2)
        let insets = UIEdgeInsets(top: vertical, left: horizontal, bottom: vertical, right: horizontal)
        if contentInset != insets { contentInset = insets }
        imageView.accessibilityValue = "\(Int((zoomScale * 100).rounded()))%"
    }
    @objc private func tapped(_ gesture: UITapGestureRecognizer) {
        reportViewport()
        tap(zoomScale > 1.01 ? 0.5 : (gesture.location(in: self).x - bounds.minX) / max(1, bounds.width))
    }
    @objc private func held(_ gesture: UILongPressGestureRecognizer) {
        let x = (gesture.location(in: self).x - bounds.minX) / max(1, bounds.width)
        if gesture.state == .began, bookmarkRange.contains(x) { bookmark() }
    }
    @objc private func doubleTapped(_ gesture: UITapGestureRecognizer) {
        if zoomScale > 1.1 { setZoomScale(1, animated: true) }
        else {
            let point = gesture.location(in: imageView)
            let size = CGSize(width: bounds.width / 2.5, height: bounds.height / 2.5)
            zoom(to: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2, width: size.width, height: size.height), animated: true)
        }
    }
}

struct ReaderSpreadView: View {
    let gallery: NativeGallery
    let images: PageImageStore
    let start: Int
    let count: Int
    let rtl: Bool
    let tap: (CGFloat) -> Void
    let bookmark: () -> Void
    let viewport: (Int, CGRect, CGFloat) -> Void
    var body: some View {
        let indices = Array(start..<min(gallery.pages.count, start + ReaderLayout.count(count)))
        HStack(spacing: 2) {
            ForEach(rtl ? indices.reversed().map { $0 } : indices, id: \.self) { index in
                let slot = rtl ? indices.count - 1 - (index - start) : index - start
                ReaderPageView(page: gallery.pages[index], galleryID: gallery.id, images: images,
                               tap: { x in
                                   tap((CGFloat(slot) + x) / CGFloat(indices.count))
                               }, bookmark: bookmark, viewport: { rect, scale in viewport(index, rect, scale) },
                               bookmarkRange: (0.3 * CGFloat(indices.count) - CGFloat(slot))...(0.7 * CGFloat(indices.count) - CGFloat(slot)))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

struct ReaderPager: UIViewControllerRepresentable {
    let gallery: NativeGallery
    let images: PageImageStore
    let vertical: Bool
    let rtl: Bool
    @Binding var current: Int
    let tap: (CGFloat) -> Void
    let bookmark: () -> Void
    let count: Int
    let viewport: (Int, CGRect, CGFloat) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIViewController(context: Context) -> UIPageViewController {
        let controller = UIPageViewController(transitionStyle: .scroll, navigationOrientation: vertical ? .vertical : .horizontal)
        controller.view.backgroundColor = .black
        controller.dataSource = context.coordinator
        controller.delegate = context.coordinator
        controller.setViewControllers([context.coordinator.page(current)], direction: .forward, animated: false)
        return controller
    }
    func updateUIViewController(_ controller: UIPageViewController, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        let shown = controller.viewControllers?.first as? PageController
        if let shown, shown.index == current {
            shown.rootView = coordinator.content(current)
        } else if !coordinator.transitioning {
            let forward = current > (shown?.index ?? 0)
            let reversed = rtl && !vertical
            controller.setViewControllers([coordinator.page(current)], direction: forward != reversed ? .forward : .reverse, animated: false)
        }
        coordinator.trim(around: current)
    }
    final class PageController: UIHostingController<ReaderSpreadView> {
        let index: Int
        init(index: Int, content: ReaderSpreadView) { self.index = index; super.init(rootView: content); view.backgroundColor = .black; safeAreaRegions = [] }
        @MainActor required dynamic init?(coder aDecoder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    }
    final class Coordinator: NSObject, UIPageViewControllerDataSource, UIPageViewControllerDelegate {
        var parent: ReaderPager
        var pages: [Int: PageController] = [:]
        var transitioning = false
        init(_ parent: ReaderPager) { self.parent = parent }
        func content(_ index: Int) -> ReaderSpreadView {
            ReaderSpreadView(gallery: parent.gallery, images: parent.images, start: index, count: parent.count,
                             rtl: parent.rtl, tap: parent.tap,
                             bookmark: parent.bookmark, viewport: parent.viewport)
        }
        func page(_ index: Int) -> PageController {
            if let existing = pages[index] { existing.rootView = content(index); return existing }
            let page = PageController(index: index, content: content(index))
            pages[index] = page
            return page
        }
        func trim(around index: Int) { pages = pages.filter { abs($0.key - index) <= parent.count } }
        func adjacent(_ controller: UIViewController, offset: Int) -> UIViewController? {
            guard let current = controller as? PageController else { return nil }
            let next = current.index + offset * parent.count * (parent.rtl && !parent.vertical ? -1 : 1)
            return parent.gallery.pages.indices.contains(next) ? page(next) : nil
        }
        func pageViewController(_ pageViewController: UIPageViewController, viewControllerBefore viewController: UIViewController) -> UIViewController? { adjacent(viewController, offset: -1) }
        func pageViewController(_ pageViewController: UIPageViewController, viewControllerAfter viewController: UIViewController) -> UIViewController? { adjacent(viewController, offset: 1) }
        func pageViewController(_ pageViewController: UIPageViewController, willTransitionTo pendingViewControllers: [UIViewController]) { transitioning = true }
        func pageViewController(_ controller: UIPageViewController, didFinishAnimating finished: Bool, previousViewControllers: [UIViewController], transitionCompleted completed: Bool) {
            transitioning = false
            if completed, let page = controller.viewControllers?.first as? PageController { parent.current = page.index }
        }
    }
}

struct ReaderContinuousView: View {
    let gallery: NativeGallery
    let images: PageImageStore
    @Binding var current: Int
    let tap: (CGFloat) -> Void
    let bookmark: () -> Void
    let count: Int
    let rtl: Bool
    let viewport: (Int, CGRect, CGFloat) -> Void
    @State private var position: Int?

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(Array(stride(from: 0, to: gallery.pages.count, by: ReaderLayout.count(count))), id: \.self) { index in
                        let indices = index..<min(gallery.pages.count, index + count)
                        let ratio = indices.map { CGFloat(max(1, gallery.pages[$0].height)) / CGFloat(max(1, gallery.pages[$0].width)) }.max() ?? 1
                        ReaderSpreadView(gallery: gallery, images: images, start: index, count: count, rtl: rtl,
                                         tap: tap, bookmark: bookmark, viewport: viewport)
                            .frame(height: geometry.size.width / CGFloat(indices.count) * ratio)
                            .id(index)
                    }
                }.scrollTargetLayout()
            }
            .scrollIndicators(.hidden)
            .scrollPosition(id: $position, anchor: .top)
            .onAppear { position = current }
            .onChange(of: position) { _, value in if let value, current != value { current = value } }
            .onChange(of: current) { _, value in if position != value { position = value } }
        }
    }
}

/// Observes a deliberate downward drag without stealing page scrolling or pinch gestures.
struct ReaderExitGesture: UIViewRepresentable {
    var enabled: Bool
    let progress: (CGFloat) -> Void
    let exit: () -> Void
    func makeUIView(context: Context) -> ExitGestureView { ExitGestureView() }
    func updateUIView(_ view: ExitGestureView, context: Context) { view.exit = exit; view.progress = progress; view.pan.isEnabled = enabled }
    static func dismantleUIView(_ view: ExitGestureView, coordinator: ()) { view.pan.view?.removeGestureRecognizer(view.pan) }
}
final class ExitGestureView: UIView, UIGestureRecognizerDelegate {
    var exit: () -> Void = {}
    var progress: (CGFloat) -> Void = { _ in }
    lazy var pan = UIPanGestureRecognizer(target: self, action: #selector(dragged(_:)))
    override func didMoveToWindow() {
        super.didMoveToWindow()
        pan.view?.removeGestureRecognizer(pan)
        pan.delegate = self
        pan.cancelsTouchesInView = false
        pan.maximumNumberOfTouches = 1
        window?.addGestureRecognizer(pan)
    }
    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        let velocity = pan.velocity(in: window)
        return velocity.y > 0 && velocity.y > abs(velocity.x) * 1.25
    }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard let window, window.bounds.inset(by: window.safeAreaInsets).contains(touch.location(in: window)) else { return false }
        var view = touch.view
        while let current = view {
            if current is UIControl { return false }
            if let page = current as? PageScrollView, page.zoomScale > 1.01 || page.isZooming { return false }
            view = current.superview
        }
        return true
    }
    @objc private func dragged(_ gesture: UIPanGestureRecognizer) {
        guard let window else { return }
        let delta = gesture.translation(in: window)
        switch gesture.state {
        case .began, .changed: progress(max(0, delta.y))
        case .ended:
            if ReaderDismissal.shouldExit(delta: delta, velocity: gesture.velocity(in: window)) { exit() }
            else { progress(0) }
        case .cancelled, .failed: progress(0)
        default: break
        }
    }
}

enum ReaderDismissal {
    static func shouldExit(delta: CGPoint, velocity: CGPoint) -> Bool {
        delta.y > abs(delta.x) * 1.25 && (delta.y >= 96 || (delta.y >= 24 && velocity.y >= 550))
    }
}
