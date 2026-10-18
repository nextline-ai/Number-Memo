import SwiftUI
import WebKit
import ImageIO
import UniformTypeIdentifiers

/// NSCache synchronizes lookup/insert/removal internally. Configuration stays
/// immutable after initialization, so cells can safely read completed images.
private final class BooruThumbnailMemoryCache: @unchecked Sendable {
    private let images = NSCache<NSString, UIImage>()
    init() {
        images.totalCostLimit = 128 * 1024 * 1024
        images.countLimit = 256
    }
    func object(forKey key: NSString) -> UIImage? { images.object(forKey: key) }
    func setObject(_ image: UIImage, forKey key: NSString, cost: Int) { images.setObject(image, forKey: key, cost: cost) }
    func removeAllObjects() { images.removeAllObjects() }
}

actor BooruThumbnailCache {
    static let shared = BooruThumbnailCache()
    private let cache = BooruThumbnailMemoryCache()
    private var disk: BooruThumbnailDiskCache
    private var inFlight: [String: Task<UIImage, Error>] = [:]
    private var prefetchQueue: [(key: String, url: URL, server: BooruServer)] = []
    private var prefetchKeys = Set<String>()
    private var prefetchWorkers: [UUID: Task<Void, Never>] = [:]
    private var prefetchGeneration = UUID()
    private var generation = UUID()
    private let loadData: (@Sendable (URL, BooruServer) async throws -> Data)?
    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        return URLSession(configuration: config, delegate: BooruRedirectPolicy(publicMedia: true), delegateQueue: nil)
    }()
    func clear() {
        generation = UUID(); inFlight.values.forEach { $0.cancel() }; inFlight = [:]
        cancelPrefetch()
        cache.removeAllObjects(); disk.clear()
    }
    init(directory: URL = BooruThumbnailDiskCache.defaultDirectory, diskCapacity: Int = 256 * 1024 * 1024,
         loadData: (@Sendable (URL, BooruServer) async throws -> Data)? = nil) {
        disk = .init(directory: directory, capacity: diskCapacity); self.loadData = loadData
    }
    nonisolated func cachedImage(url: URL, server: BooruServer) -> UIImage? {
        let key = server.canonicalAddress + ":" + server.id + ":" + url.absoluteString as NSString
        return cache.object(forKey: key)
    }
    nonisolated func prefetch(_ items: [(URL, BooruServer)]) {
        guard !items.isEmpty else { return }
        Task(priority: .utility) { await enqueuePrefetch(items) }
    }
    func cancelPrefetch() {
        prefetchGeneration = UUID()
        // Shared image loads can still serve a visible cell. Keep their worker
        // slots occupied until completion, even when this lookahead is canceled.
        prefetchWorkers.values.forEach { $0.cancel() }
        prefetchQueue = []; prefetchKeys = []
    }
    private func enqueuePrefetch(_ items: [(URL, BooruServer)]) {
        for (url, server) in items {
            let key = cacheKey(url, server)
            guard cache.object(forKey: key as NSString) == nil, inFlight[key] == nil,
                  prefetchKeys.insert(key).inserted else { continue }
            prefetchQueue.append((key, url, server))
        }
        // A fast fling replaces obsolete lookahead instead of starting a new
        // four-worker group for every appearing cell.
        while prefetchQueue.count > 24 {
            prefetchKeys.remove(prefetchQueue.removeFirst().key)
        }
        startPrefetchWorkers()
    }
    private func startPrefetchWorkers() {
        while prefetchWorkers.count < 2, !prefetchQueue.isEmpty {
            let item = prefetchQueue.removeFirst(), id = UUID(), captured = prefetchGeneration
            prefetchWorkers[id] = Task(priority: .utility) {
                _ = try? await image(url: item.url, server: item.server)
                if captured == prefetchGeneration { prefetchKeys.remove(item.key) }
                prefetchWorkers[id] = nil
                startPrefetchWorkers()
            }
        }
    }
    private func cacheKey(_ url: URL, _ server: BooruServer) -> String { server.canonicalAddress + ":" + server.id + ":" + url.absoluteString }
    func translationImage(post: BooruPost, server: BooruServer, rect: CGRect) async throws -> UIImage {
        #if DEBUG
        if BooruUITestSupport.enabled {
            return await MainActor.run {
                UIGraphicsImageRenderer(size: CGSize(width: 800, height: 1000)).image { context in
                    UIColor.white.setFill(); context.fill(CGRect(x: 0, y: 0, width: 800, height: 1000))
                    ("今日はいい天気です。\n\n一緒に公園に行きましょう。" as NSString).draw(in: CGRect(x: 50, y: 100, width: 700, height: 800), withAttributes: [.font: UIFont.systemFont(ofSize: 42), .foregroundColor: UIColor.black])
                }
            }
        }
        #endif
        guard let url = post.viewerURL(original: true) else { throw BooruError.invalidResponse }
        let data = try await BooruViewerImageCache.shared.data(url: url, server: server)
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else { throw BooruError.invalidResponse }
        return try ReaderTranslationImage.decode(source: source, rect: rect)
    }
    func image(url: URL, server: BooruServer) async throws -> UIImage {
        let key = cacheKey(url, server)
        if let image = cache.object(forKey: key as NSString) { return image }
        if let pending = inFlight[key] { return try await pending.value }
        if let data = disk.read(key) {
            if let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
               let image = Self.thumbnail(source) {
                cache.setObject(image, forKey: key as NSString, cost: image.cgImage.map { $0.bytesPerRow * $0.height } ?? data.count)
                return image
            }
            disk.remove(key)
        }
        let captured = generation
        // A shared load survives cell reuse and feeds both memory and disk caches.
        let task = Task<UIImage, Error> {
            let (source, file) = try await imageSource(url, server: server)
            defer { if let file { try? FileManager.default.removeItem(at: file) } }
            try Task.checkCancellation()
            guard captured == generation, let image = Self.thumbnail(source), let cgImage = image.cgImage else { throw BooruError.invalidResponse }
            cache.setObject(image, forKey: key as NSString, cost: cgImage.bytesPerRow * cgImage.height)
            if let data = image.pngData() { disk.write(data, key: key) }
            return image
        }
        inFlight[key] = task
        defer { if captured == generation { inFlight[key] = nil } }
        return try await task.value
    }

    private static func thumbnail(_ source: CGImageSource) -> UIImage? {
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 600, kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else { return nil }
        // Disk hits must be decoded off the main actor too; UIImage(data:)
        // leaves that work until SwiftUI first draws the cell.
        return UIImage(cgImage: image)
    }

    private func imageSource(_ url: URL, server: BooruServer) async throws -> (CGImageSource, URL?) {
        if let loadData {
            let data = try await loadData(url, server)
            guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else { throw BooruError.invalidResponse }
            return (source, nil)
        }
        let request = await BooruBrowserSession.prepare(URLRequest(url: url), server: server)
        do {
            let (file, response) = try await session.download(for: request)
            do {
                try Task.checkCancellation()
                guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                      let source = CGImageSourceCreateWithURL(file as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { throw BooruError.invalidResponse }
                return (source, file)
            } catch { try? FileManager.default.removeItem(at: file); throw error }
        } catch {
            try Task.checkCancellation()
            guard await BooruWebTransport.hasSession(for: server) else { throw error }
            let data = try await BooruWebTransport.imageData(url: url, server: server)
            guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else { throw BooruError.invalidResponse }
            return (source, nil)
        }
    }
}

struct BooruThumbnail: View {
    let post: BooruPost
    let server: BooruServer
    @State private var image: UIImage?
    @State private var failed = false
    @State private var retry = 0
    @SwiftUI.AppStorage("booru.fitThumbnails", store: ReaderPreferences.booruDefaults) private var fitThumbnails = false

    init(post: BooruPost, server: BooruServer) {
        self.post = post
        self.server = server
        if let url = post.previewURL ?? post.sampleURL {
            _image = State(initialValue: BooruThumbnailCache.shared.cachedImage(url: url, server: server))
        }
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color(uiColor: .tertiarySystemFill)
                if let image { Image(uiImage: image).resizable().aspectRatio(contentMode: fitThumbnails ? .fit : .fill).frame(width: geometry.size.width, height: geometry.size.height).clipped() }
                else if isFixture {
                    LinearGradient(colors: [.indigo, .cyan.opacity(0.6)], startPoint: .topLeading, endPoint: .bottomTrailing)
                    Image(systemName: "mountain.2.fill").font(.system(size: 56)).foregroundStyle(.white.opacity(0.8))
                } else if failed { Image(systemName: "photo.badge.exclamationmark").foregroundStyle(.secondary) }
                else { ProgressView() }
            }
        }.allowsHitTesting(false).onReceive(NotificationCenter.default.publisher(for: .booruClientValidated)) { if $0.object as? String == server.id { retry += 1 } }
        .task(id: "\(post.id):\(post.previewURL?.absoluteString ?? post.sampleURL?.absoluteString ?? ""):\(retry)") {
            if image == nil { failed = false }
            #if DEBUG
            if isFixture {
                // Exercise the same image rendering path as real wide thumbnails.
                image = UIGraphicsImageRenderer(size: CGSize(width: 1600, height: 300)).image { context in
                    UIColor.systemIndigo.setFill(); context.fill(CGRect(x: 0, y: 0, width: 1600, height: 300))
                    UIColor.systemCyan.setFill(); context.fill(CGRect(x: 800, y: 0, width: 800, height: 300))
                }
                return
            }
            #endif
            guard !isFixture, let url = post.previewURL ?? post.sampleURL else { failed = true; return }
            if image == nil, let cached = BooruThumbnailCache.shared.cachedImage(url: url, server: server) {
                image = cached
                return
            }
            do {
                let loaded = try await BooruThumbnailCache.shared.image(url: url, server: server)
                try Task.checkCancellation()
                image = loaded
            }
            catch { if !Task.isCancelled { failed = true } }
        }
    }
    private var isFixture: Bool {
        #if DEBUG
        return BooruUITestSupport.enabled
        #else
        return false
        #endif
    }
}

/// A minimal local media document: no website HTML, ads or third-party scripts.
/// WebKit decodes GIF/WebP lazily and provides pinch zoom and hardware video playback.
enum BooruMediaGesture {
    case tap(CGFloat), hold, swipe(Int), dismiss, zoom(Bool), viewport(CGRect), shortcut(ReaderShortcut)
}

/// Holds useful pixels across local-document replacement. A cache miss takes at
/// most one snapshot; rapid swipes replace the pending destination, not the work.
@MainActor
final class BooruMediaTransition {
    let overlay: UIImageView = {
        let view = UIImageView()
        view.contentMode = .scaleAspectFit
        view.backgroundColor = .black
        view.isUserInteractionEnabled = false
        view.accessibilityElementsHidden = true
        view.isHidden = true
        view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        return view
    }()
    private struct Request {
        let id: String
        let capture: (@escaping (UIImage?) -> Void) -> Void
        let load: () -> Void
    }
    private var documentID: String?
    private var pending: Request?
    private var snapshotID: UUID?
    var hasPendingDocument: Bool { pending != nil }

    func install(in view: UIView) {
        reset()
        overlay.frame = view.bounds
        view.addSubview(overlay)
    }
    func replace(id: String, preview: UIImage?, capture: @escaping (@escaping (UIImage?) -> Void) -> Void,
                 load: @escaping () -> Void) {
        pending = Request(id: id, capture: capture, load: load)
        if let preview {
            show(preview)
            commit()
        } else if !overlay.isHidden && overlay.image != nil || documentID == nil {
            commit()
        } else {
            capturePreviousFrame()
        }
    }
    private func show(_ image: UIImage) {
        overlay.image = image; overlay.isHidden = false
        overlay.superview?.bringSubviewToFront(overlay)
    }
    private func commit() {
        guard let request = pending else { return }
        pending = nil; documentID = request.id
        request.load()
    }
    private func capturePreviousFrame() {
        guard snapshotID == nil, let request = pending else { return }
        let token = UUID(), sourceID = documentID
        snapshotID = token
        request.capture { [weak self] image in
            guard let self, self.snapshotID == token else { return }
            self.snapshotID = nil
            guard self.pending != nil else { return }
            // A newer cached destination may already have replaced this source.
            // Its late snapshot cannot cover that document or its successor.
            guard self.documentID == sourceID else { self.capturePreviousFrame(); return }
            if let image { self.show(image) }
            self.commit()
        }
    }
    func presented(id: String) {
        guard documentID == id, pending == nil else { return }
        overlay.isHidden = true; overlay.image = nil
    }
    func failed(id: String) {
        guard documentID == id || pending?.id == id else { return }
        pending = nil
        overlay.isHidden = true; overlay.image = nil
    }
    func reset() {
        snapshotID = nil; pending = nil; documentID = nil
        overlay.isHidden = true; overlay.image = nil
    }
}

struct BooruMediaView: UIViewRepresentable {
    let post: BooruPost
    let server: BooruServer
    let original: Bool
    var active = true
    var failed = false
    let notes: [BooruNote]
    let showNotes: Bool
    let onNote: (BooruNote) -> Void
    let onStatus: (String) -> Void
    let onGesture: (BooruMediaGesture) -> Void
    var onGoldRequired: () -> Void = {}

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIView(context: Context) -> WKWebView {
        // SwiftUI can replace the UIKit view while retaining its coordinator.
        // A cached key describes the old web view, not the new empty document.
        context.coordinator.key = ""
        context.coordinator.ready = false
        context.coordinator.renderedNotes = nil
        let config = WKWebViewConfiguration()
        config.websiteDataStore = BooruBrowserSession.dataStore(for: server)
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.setURLSchemeHandler(context.coordinator.resources, forURLScheme: "numbermemo-image")
        config.userContentController.add(context.coordinator, name: "media")
        let view = WKWebView(frame: .zero, configuration: config)
        view.isOpaque = false; view.backgroundColor = .black; view.scrollView.backgroundColor = .black
        view.navigationDelegate = context.coordinator
        view.scrollView.bounces = false
        view.scrollView.contentInsetAdjustmentBehavior = .never
        view.scrollView.showsVerticalScrollIndicator = false
        view.scrollView.showsHorizontalScrollIndicator = false
        view.accessibilityIdentifier = "booru.media"
        context.coordinator.observeLifecycle(of: view)
        context.coordinator.transition.install(in: view)
        return view
    }
    func updateUIView(_ view: WKWebView, context: Context) {
        let coordinator = context.coordinator
        coordinator.onNote = onNote; coordinator.onStatus = onStatus; coordinator.notes = notes
        coordinator.showNotes = showNotes
        coordinator.onGesture = onGesture
        coordinator.onGoldRequired = onGoldRequired
        let url = post.viewerURL(original: original)
        let key = post.id + ":" + (url?.absoluteString ?? "")
        if coordinator.key != key {
            coordinator.resources.cancel()
            coordinator.key = key
            coordinator.ready = false
            coordinator.restrictedDocumentID = nil
            coordinator.renderedNotes = nil
            coordinator.width = max(post.width, 1); coordinator.height = max(post.height, 1)
            var displayURL = url
            if !post.isVideo, let url, url.scheme == "https" {
                coordinator.resources.source = url; coordinator.resources.server = server
                displayURL = URL(string: "numbermemo-image://media/" + UUID().uuidString)
            }
            coordinator.documentID = UUID().uuidString
            let expectedDocument = coordinator.documentID
            coordinator.resources.onGoldRequired = { [weak coordinator] in
                coordinator?.rejectGoldRestrictedDocument(expectedDocument)
            }
            // A snapshot can finish after activity changes. Every new document
            // starts suspended; didFinish applies the current native policy.
            coordinator.document = url == nil ? "" : Self.document(post: post, url: displayURL, identifier: coordinator.documentID)
            coordinator.baseURL = server.baseURL
            let preview = (post.previewURL ?? post.sampleURL).flatMap { BooruThumbnailCache.shared.cachedImage(url: $0, server: server) }
            let expected = coordinator.documentID
            coordinator.transition.replace(id: expected, preview: preview, capture: { [weak view] completion in
                guard let view else { completion(nil); return }
                let config = WKSnapshotConfiguration()
                config.afterScreenUpdates = true
                config.snapshotWidth = NSNumber(value: Double(min(view.bounds.width, 480)))
                view.takeSnapshot(with: config) { image, _ in completion(image) }
            }, load: { [weak coordinator, weak view] in
                guard let coordinator, let view, coordinator.documentID == expected else { return }
                if coordinator.document.isEmpty {
                    // Public Gelbooru rows only have a thumbnail. Keep the same
                    // web view and held frame while its media URL resolves.
                    coordinator.pause()
                } else {
                    view.scrollView.setZoomScale(view.scrollView.minimumZoomScale, animated: false)
                    view.loadHTMLString(coordinator.document, baseURL: coordinator.baseURL)
                }
            })
        } else { coordinator.updateNotes(view) }
        if failed {
            coordinator.transition.failed(id: coordinator.documentID)
            coordinator.pause()
        }
        if coordinator.active != active {
            coordinator.active = active
            if active { coordinator.resume() }
            else { coordinator.pause() }
        }
    }
    static func dismantleUIView(_ view: WKWebView, coordinator: Coordinator) {
        NotificationCenter.default.removeObserver(coordinator)
        coordinator.pause()
        coordinator.view = nil
        coordinator.key = ""; coordinator.ready = false
        view.navigationDelegate = nil
        view.stopLoading()
        coordinator.resources.cancel()
        coordinator.transition.reset()
        view.configuration.userContentController.removeScriptMessageHandler(forName: "media")
        view.loadHTMLString("", baseURL: nil)
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }
    static func document(post: BooruPost, url: URL?, identifier: String = "", active: Bool = false) -> String {
        var source = url?.absoluteString ?? ""
        #if DEBUG
        if BooruUITestSupport.enabled {
            let svg = "<svg xmlns='http://www.w3.org/2000/svg' width='1600' height='1200'><rect width='1600' height='1200' fill='#193655'/><path d='M0 1000 L500 250 L850 750 L1150 400 L1600 1000' fill='#65c8cf'/><text x='140' y='160' font-size='64' fill='white'>Booru · Post \(post.postID)</text></svg>"
            source = "data:image/svg+xml;base64," + Data(svg.utf8).base64EncodedString()
            if post.fileExtension == "gif" { source = BooruTestMedia.gif }
            if post.fileExtension == "mp4" { source = BooruTestMedia.mp4 }
        }
        #endif
        let isVideo = post.isVideo
        let suspendsImage = post.isAnimated && !isVideo
        let sourceAttribute = active || !isVideo && !suspendsImage ? " src='\(escape(source))'" : ""
        let media = isVideo
            ? "<video id='media' data-source='\(escape(source))'\(sourceAttribute) controls playsinline autoplay muted preload='metadata'></video>"
            : "<img id='media' data-source='\(escape(source))'\(sourceAttribute) alt='Post \(post.postID)' />"
        let nonce = UUID().uuidString
        return """
        <!doctype html><html><head><meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=8, user-scalable=yes">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src https: data: numbermemo-image:; media-src https: blob: data:; style-src 'unsafe-inline'; script-src 'nonce-\(nonce)'; base-uri 'none'; form-action 'none'">
        <meta name="referrer" content="origin"><style>
        html,body{margin:0;width:100%;height:100%;background:#000;color:white;-webkit-touch-callout:none;-webkit-user-select:none}body{display:flex;align-items:center;justify-content:center}
        #canvas{position:relative;flex:none}#media{display:block;width:100%;height:100%;object-fit:contain;visibility:hidden}
        #notes{position:absolute;inset:0;pointer-events:none}.note{position:absolute;box-sizing:border-box;border:2px solid #ffd45a;background:#ffd45a30;color:white;pointer-events:auto;padding:0;min-width:18px;min-height:18px;text-align:left}
        .note span{background:#202020dd;padding:2px 5px;font:12px -apple-system;border-radius:4px}
        </style></head><body><div id="canvas">\(media)<div id="notes"></div></div>
        <script nonce="\(nonce)">
        window.numberMemoDocumentID='\(identifier)';
        const media=document.getElementById('media');
        const send=value=>window.webkit.messageHandlers.media.postMessage({...value,documentID:'\(identifier)'});
        const fit=()=>{const w=media.naturalWidth||media.videoWidth||\(max(post.width, 1));const h=media.naturalHeight||media.videoHeight||\(max(post.height, 1));
          const scale=Math.min(document.body.clientWidth/w,document.body.clientHeight/h);const canvas=document.getElementById('canvas');canvas.style.width=(w*scale)+'px';canvas.style.height=(h*scale)+'px';};
        let retries=0,retryTimer=null,pendingMediaError=false;
        const retryMedia=()=>{
          if(!media.hasAttribute('src'))return;
          if(!playbackAllowed){pendingMediaError=true;return;}
          pendingMediaError=false;
          if(retries>=2){send({status:'error'});return;}
          send({status:'loading'});clearTimeout(retryTimer);
          retryTimer=setTimeout(()=>{retryTimer=null;
            if(!playbackAllowed){pendingMediaError=true;return;}
            retries++;media.removeAttribute('src');media.setAttribute('src',media.dataset.source);
            if(media.tagName==='VIDEO')media.load();},(retries+1)*500);
        };
        media.addEventListener('error',retryMedia);
        let readinessRevision=0;
        const presentMedia=async()=>{
          const revision=++readinessRevision,source=media.getAttribute('src');
          if(media.tagName==='IMG'&&media.decode){try{await media.decode();}catch{return;}}
          if(!source||revision!==readinessRevision||media.getAttribute('src')!==source)return;
          pendingMediaError=false;clearTimeout(retryTimer);retryTimer=null;
          fit();media.style.visibility='visible';
          // Decode completion alone precedes presentation. Keep native transition
          // pixels until the visible media has crossed a browser paint boundary.
          await new Promise(requestAnimationFrame);await new Promise(requestAnimationFrame);
          if(revision!==readinessRevision||media.getAttribute('src')!==source)return;
          const status=media.tagName==='VIDEO'?(media.ended?'ended':media.paused?'ready':'playing'):'ready';
          send({status:status,presented:true});
        };
        media.addEventListener('load',presentMedia);
        media.addEventListener('loadedmetadata',()=>{fit();});
        media.addEventListener('loadeddata',presentMedia);
        media.addEventListener('playing',()=>send({status:'playing'}));
        media.addEventListener('ended',()=>send({status:'ended'}));
        let playTimer=null,playAttempts=0,playbackAllowed=\(active ? "true" : "false");
        const restoreSource=()=>{if(!media.hasAttribute('src'))media.setAttribute('src',media.dataset.source);};
        const play=()=>{
          if(!playbackAllowed||media.tagName!=='VIDEO'||document.hidden)return;
          clearTimeout(playTimer);
          media.muted=true;media.playsInline=true;
          const result=media.play();
          result?.catch(()=>{if(++playAttempts<5)playTimer=setTimeout(play,400*playAttempts);});
        };
        const suspendPlayback=()=>{clearTimeout(playTimer);
          if(retryTimer!==null){pendingMediaError=true;clearTimeout(retryTimer);retryTimer=null;}
          if(media.tagName==='VIDEO')media.pause();
          if(\(suspendsImage ? "true" : "false")){readinessRevision++;media.removeAttribute('src');}};
        window.resumePlayback=()=>{playbackAllowed=true;playAttempts=0;restoreSource();if(pendingMediaError)retryMedia();play();};
        window.pausePlayback=()=>{playbackAllowed=false;suspendPlayback();};
        // Page visibility must never override the native viewer's activity gate.
        window.addEventListener('pageshow',()=>{if(playbackAllowed){restoreSource();play();}});
        document.addEventListener('visibilitychange',()=>{
          if(document.hidden)suspendPlayback();else if(playbackAllowed){restoreSource();play();}
        });
        if(media.tagName==='VIDEO') {
          send({status:'loading'});
          media.addEventListener('canplay',play);
          media.addEventListener('loadeddata',play);
          play();
        }
        window.addEventListener('resize',fit);fit();
        let start=null,holdTimer=null,tapTimer=null,lastTap=0,held=false,lastTouchAt=0;
        const zoom=()=>window.visualViewport?.scale||1;
        let viewportFrame=null,lastViewport=null,lastZoom=null;
        const reportViewport=()=>{
          // WebKit's boundingClientRect already includes the visual viewport pan.
          // Use document coordinates throughout, avoiding a second pan offset.
          let imageLeft=0,imageTop=0,node=media;
          while(node){imageLeft+=node.offsetLeft;imageTop+=node.offsetTop;node=node.offsetParent;}
          const width=media.clientWidth,height=media.clientHeight,v=window.visualViewport;
          if(!width||!height)return;
          const left=v?.pageLeft??window.scrollX,top=v?.pageTop??window.scrollY;
          const right=left+(v?.width||innerWidth),bottom=top+(v?.height||innerHeight);
          const x=Math.max(0,Math.min(1,(left-imageLeft)/width)),y=Math.max(0,Math.min(1,(top-imageTop)/height));
          const rect={x:x,y:y,w:Math.max(0,Math.min(1,(right-imageLeft)/width)-x),h:Math.max(0,Math.min(1,(bottom-imageTop)/height)-y)};
          if(!lastViewport||Object.keys(rect).some(key=>Math.abs(rect[key]-lastViewport[key])>0.0001)){
            lastViewport=rect;send({viewport:rect});
          }
          const zoomed=zoom()>1.01;
          if(zoomed!==lastZoom){lastZoom=zoomed;send({scale:zoom()});}
        };
        const viewport=()=>{if(viewportFrame!==null)return;viewportFrame=requestAnimationFrame(()=>{viewportFrame=null;reportViewport();});};
        media.addEventListener('load',viewport);
        window.visualViewport?.addEventListener('resize',viewport);
        window.visualViewport?.addEventListener('scroll',viewport);
        window.addEventListener('scroll',viewport);
        window.addEventListener('resize',viewport);
        const cancelHold=()=>{clearTimeout(holdTimer);holdTimer=null;};
        document.addEventListener('touchstart',e=>{
          lastTouchAt=Date.now();cancelHold();held=false;
          if(e.touches.length!==1||e.target.closest('button')){start=null;return;}
          const t=e.touches[0],video=!!e.target.closest('video');
          if(video&&t.clientY>media.getBoundingClientRect().bottom-56){start=null;return;}
          start={x:t.clientX,y:t.clientY,time:Date.now(),zoom:zoom(),video:video};
          holdTimer=setTimeout(()=>{if(start){clearTimeout(tapTimer);held=true;send({gesture:'hold'});}},550);
        },{passive:true});
        document.addEventListener('touchmove',e=>{
          if(!start)return;
          if(e.touches.length!==1){start=null;cancelHold();return;}
          const t=e.touches[0];if(Math.hypot(t.clientX-start.x,t.clientY-start.y)>10)cancelHold();
          if(start.zoom<=1.01&&zoom()<=1.01)e.preventDefault();
        },{passive:false});
        document.addEventListener('touchcancel',()=>{start=null;cancelHold();},{passive:true});
        document.addEventListener('touchend',e=>{
          lastTouchAt=Date.now();cancelHold();if(!start)return;
          const s=start;start=null;if(held||e.touches.length)return;
          const t=e.changedTouches[0],dx=t.clientX-s.x,dy=t.clientY-s.y,elapsed=Math.max(1,Date.now()-s.time);
          const atOriginal=s.zoom<=1.01&&zoom()<=1.01;
          if(atOriginal&&Math.abs(dx)>50&&Math.abs(dx)>Math.abs(dy)*1.3){clearTimeout(tapTimer);send({gesture:'swipe',delta:dx<0?1:-1});return;}
          if(atOriginal&&dy>Math.abs(dx)*1.25&&(dy>=96||(dy>=24&&dy/elapsed>=0.55))){clearTimeout(tapTimer);send({gesture:'dismiss'});return;}
          if(Math.hypot(dx,dy)>10||s.video)return;
          const now=Date.now();
          if(now-lastTap<300){clearTimeout(tapTimer);lastTap=0;e.preventDefault();send({gesture:'double',x:t.clientX/innerWidth,y:t.clientY/innerHeight});}
          else{lastTap=now;tapTimer=setTimeout(()=>send({gesture:'tap',x:atOriginal?t.clientX/innerWidth:0.5}),300);}
        },{passive:false});
        // Mouse clicks are not touch events. Ignore compatibility clicks generated
        // after touch so a tap never navigates twice; leave video controls intact.
        document.addEventListener('click',e=>{
          if(Date.now()-lastTouchAt<700||e.target.closest('button,video'))return;
          clearTimeout(tapTimer);
          if(e.detail>1)return;
          tapTimer=setTimeout(()=>send({gesture:'tap',x:zoom()<=1.01?e.clientX/innerWidth:0.5}),300);
        });
        document.addEventListener('dblclick',e=>{
          if(Date.now()-lastTouchAt<700||e.target.closest('button,video'))return;
          clearTimeout(tapTimer);e.preventDefault();
          send({gesture:'double',x:e.clientX/innerWidth,y:e.clientY/innerHeight});
        });
        document.addEventListener('contextmenu',e=>{
          if(e.target.closest('button,video'))return;
          e.preventDefault();clearTimeout(tapTimer);send({gesture:'tap',x:0.5});
        });
        document.addEventListener('keydown',e=>{
          if(e.metaKey||e.ctrlKey||e.altKey||e.shiftKey||e.target.closest('input,textarea,[contenteditable="true"]'))return;
          const key=e.key.length===1?e.key.toLowerCase():e.key;
          if(!['Escape','ArrowLeft','ArrowRight','m','f','i'].includes(key))return;
          // Space and up/down retain native video playback/volume behavior.
          e.preventDefault();e.stopPropagation();
          if(!e.repeat)send({gesture:'shortcut',key:key});
        },true);
        window.renderNotes=(notes,visible)=>{const layer=document.getElementById('notes');layer.replaceChildren();layer.hidden=!visible;
          notes.forEach((note,index)=>{const b=document.createElement('button');b.className='note';b.setAttribute('aria-label','Note '+(index+1));
          b.style.left=note.x+'%';b.style.top=note.y+'%';b.style.width=note.w+'%';b.style.height=note.h+'%';
          const label=document.createElement('span');label.textContent=index+1;b.appendChild(label);b.onclick=()=>send({note:index});layer.appendChild(b);});};
        </script></body></html>
        """
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        weak var view: WKWebView?
        func observeLifecycle(of view: WKWebView) {
            NotificationCenter.default.removeObserver(self)
            self.view = view
            NotificationCenter.default.addObserver(self, selector: #selector(resume), name: UIApplication.didBecomeActiveNotification, object: nil)
            NotificationCenter.default.addObserver(self, selector: #selector(pause), name: UIApplication.willResignActiveNotification, object: nil)
        }
        private var playbackGeneration: UInt = 0
        private var resumeRetry: Task<Void, Never>?
        @objc func pause() {
            playbackGeneration &+= 1
            resumeRetry?.cancel(); resumeRetry = nil
            view?.evaluateJavaScript("window.pausePlayback?.()", completionHandler: nil)
        }
        @objc func resume() {
            playbackGeneration &+= 1
            resumeRetry?.cancel(); resumeRetry = nil
            resumeCheckingDocument(retryAllowed: true)
        }
        private func resumeCheckingDocument(retryAllowed: Bool) {
            guard active, restrictedDocumentID != documentID, UIApplication.shared.applicationState == .active, !transition.hasPendingDocument,
                  let view, !document.isEmpty else { return }
            let expected = documentID, generation = playbackGeneration
            // Validate the document as well as playback: WebKit may suspend a
            // pending page transition while the app is in the background.
            view.evaluateJavaScript("window.numberMemoDocumentID === '\(expected)'") { [weak self, weak view] value, error in
                guard let self, let view, self.active, UIApplication.shared.applicationState == .active,
                      self.playbackGeneration == generation, self.view === view, self.documentID == expected else { return }
                guard error == nil, let matchesDocument = value as? Bool else {
                    // A temporarily suspended JavaScript context is not evidence
                    // that the document disappeared. Retry playback once, preserving
                    // the existing document, zoom and scroll position on failure.
                    guard retryAllowed else { return }
                    self.resumeRetry?.cancel()
                    self.resumeRetry = Task { [weak self, weak view] in
                        do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
                        guard let self, let view, self.playbackGeneration == generation,
                              self.view === view, self.documentID == expected else { return }
                        self.resumeRetry = nil
                        self.resumeCheckingDocument(retryAllowed: false)
                    }
                    return
                }
                if matchesDocument {
                    view.evaluateJavaScript("window.resumePlayback?.()", completionHandler: nil)
                } else {
                    self.ready = false
                    view.loadHTMLString(self.document, baseURL: self.baseURL)
                }
            }
        }
        let resources = BooruImageResourceHandler()
        let transition = BooruMediaTransition()
        var key = ""
        var ready = false
        var active = true
        var documentID = ""
        var restrictedDocumentID: String?
        var document = ""
        var baseURL: URL?
        var width = 1
        var height = 1
        var notes: [BooruNote] = []
        var showNotes = false
        var renderedNotes: [BooruNote]?
        private var renderedShowNotes = false
        var onNote: ((BooruNote) -> Void)?
        var onStatus: ((String) -> Void)?
        var onGesture: ((BooruMediaGesture) -> Void)?
        var onGoldRequired: (() -> Void)?
        func rejectGoldRestrictedDocument(_ id: String) {
            guard documentID == id, restrictedDocumentID != id else { return }
            restrictedDocumentID = id
            pause()
            onGoldRequired?()
        }
        func updateNotes(_ view: WKWebView) {
            guard ready, renderedNotes != notes || renderedShowNotes != showNotes else { return }
            let values = notes.map { note -> [String: Double] in
                ["x": max(0, min(100, note.x / Double(width) * 100)), "y": max(0, min(100, note.y / Double(height) * 100)),
                 "w": max(0, min(100, note.width / Double(width) * 100)), "h": max(0, min(100, note.height / Double(height) * 100))]
            }
            guard let data = try? JSONSerialization.data(withJSONObject: values), let json = String(data: data, encoding: .utf8) else { return }
            renderedNotes = notes; renderedShowNotes = showNotes
            view.evaluateJavaScript("window.renderNotes(\(json), \(showNotes ? "true" : "false"));", completionHandler: nil)
        }
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard restrictedDocumentID != documentID, message.frameInfo.isMainFrame,
                  let value = message.body as? [String: Any], value["documentID"] as? String == documentID else { return }
            if let index = value["note"] as? Int, notes.indices.contains(index) { onNote?(notes[index]) }
            if value["presented"] as? Bool == true { transition.presented(id: documentID) }
            if let status = value["status"] as? String {
                if status == "error" { transition.failed(id: documentID) }
                onStatus?(status)
            }
            if let rect = value["viewport"] as? [String: Double], let x = rect["x"], let y = rect["y"], let w = rect["w"], let h = rect["h"], w > 0, h > 0 {
                onGesture?(.viewport(CGRect(x: x, y: y, width: w, height: h)))
            }
            if let scale = value["scale"] as? Double { onGesture?(.zoom(scale > 1.01)) }
            switch value["gesture"] as? String {
            case "shortcut":
                if let key = value["key"] as? String, let command = ReaderShortcut(rawValue: key) { onGesture?(.shortcut(command)) }
            case "tap": onGesture?(.tap(value["x"] as? Double ?? 0.5))
            case "hold": onGesture?(.hold)
            case "swipe": onGesture?(.swipe(value["delta"] as? Int ?? 0))
            case "dismiss": onGesture?(.dismiss)
            case "double":
                guard let view = message.webView else { return }
                let scroll = view.scrollView
                if scroll.zoomScale > scroll.minimumZoomScale * 1.01 { scroll.setZoomScale(scroll.minimumZoomScale, animated: true) }
                else {
                    let scale = min(scroll.maximumZoomScale, scroll.minimumZoomScale * 2.5)
                    let point = CGPoint(x: (value["x"] as? Double ?? 0.5) * scroll.bounds.width, y: (value["y"] as? Double ?? 0.5) * scroll.bounds.height)
                    let size = CGSize(width: scroll.bounds.width / scale, height: scroll.bounds.height / scale)
                    scroll.zoom(to: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2, width: size.width, height: size.height), animated: true)
                }
            default: break
            }
        }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            ready = true; renderedNotes = nil; updateNotes(webView)
            let canPlay = active && restrictedDocumentID != documentID && !document.isEmpty && !transition.hasPendingDocument && UIApplication.shared.applicationState == .active
            webView.evaluateJavaScript(canPlay ? "window.resumePlayback?.()" : "window.pausePlayback?.()", completionHandler: nil)
        }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            guard restrictedDocumentID != documentID, (error as NSError).code != NSURLErrorCancelled else { return }
            transition.failed(id: documentID)
            onStatus?("error")
        }
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            ready = false; renderedNotes = nil
            resources.cancel()
            guard active, restrictedDocumentID != documentID, UIApplication.shared.applicationState == .active else { return }
            onStatus?("loading")
            webView.loadHTMLString(document, baseURL: baseURL)
        }
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            decisionHandler(action.navigationType == .linkActivated ? .cancel : .allow)
        }
    }
}

/// Local HTML documents do not reliably send a Referer from WebKit. Gelbooru's
/// CDN requires it. Download images with the server-scoped headers, then hand
/// the original bytes to WebKit so GIFs and large images retain native decoding.
@MainActor
final class BooruImageResourceHandler: NSObject, WKURLSchemeHandler {
    var source: URL?
    var server: BooruServer?
    var onGoldRequired: (() -> Void)?
    private var pending: [ObjectIdentifier: Task<Void, Never>] = [:]
    func cancel() {
        for task in pending.values { task.cancel() }
        pending.removeAll()
    }
    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        let id = ObjectIdentifier(urlSchemeTask)
        guard let source, let server, let localURL = urlSchemeTask.request.url else {
            urlSchemeTask.didFailWithError(BooruError.invalidResponse); return
        }
        let goldRequired = onGoldRequired
        pending[id] = Task {
            defer { pending[id] = nil }
            do {
                let data = try await BooruViewerImageCache.shared.data(url: source, server: server)
                try Task.checkCancellation()
                guard let image = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
                      let type = CGImageSourceGetType(image), let mime = UTType(type as String)?.preferredMIMEType else { throw BooruError.invalidResponse }
                urlSchemeTask.didReceive(URLResponse(url: localURL, mimeType: mime, expectedContentLength: data.count, textEncodingName: nil))
                urlSchemeTask.didReceive(data)
                try Task.checkCancellation()
                urlSchemeTask.didFinish()
            } catch {
                if !Task.isCancelled {
                    if error as? BooruPostAccessError == .goldRequired { goldRequired?() }
                    urlSchemeTask.didFailWithError(error)
                }
            }
        }
    }
    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {
        pending.removeValue(forKey: ObjectIdentifier(urlSchemeTask))?.cancel()
    }
}

/// Original encoded image bytes, separate from the small grid-thumbnail cache.
/// Visible and speculative consumers share requests. Unused downloads cancel on
/// swipe/dismissal; completed originals remain in bounded disk storage.
actor BooruViewerImageCache {
    static let shared = BooruViewerImageCache()
    private var disk: BooruThumbnailDiskCache
    private struct Flight {
        let id: UUID
        let task: Task<Void, Never>
        var waiters: [UUID: CheckedContinuation<Data, Error>]
    }
    private var inFlight: [String: Flight] = [:]
    private let loadData: (@Sendable (URL, BooruServer) async throws -> Data)?
    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.timeoutIntervalForRequest = 25
        config.timeoutIntervalForResource = 60
        return URLSession(configuration: config, delegate: BooruRedirectPolicy(publicMedia: true), delegateQueue: nil)
    }()
    init(directory: URL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("BooruViewerImages"),
         capacity: Int = 512 * 1024 * 1024, loadData: (@Sendable (URL, BooruServer) async throws -> Data)? = nil) {
        disk = .init(directory: directory, capacity: capacity, fileExtension: "media")
        self.loadData = loadData
    }
    func clear() {
        let flights = inFlight
        inFlight.removeAll()
        for flight in flights.values {
            flight.task.cancel()
            for waiter in flight.waiters.values { waiter.resume(throwing: CancellationError()) }
        }
        disk.clear()
    }
    func data(url: URL, server: BooruServer) async throws -> Data {
        try Task.checkCancellation()
        let key = server.canonicalAddress + ":" + server.id + ":" + url.absoluteString
        if let data = disk.read(key) {
            if let image = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary), CGImageSourceGetCount(image) > 0 { return data }
            disk.remove(key)
        }
        let waiter = UUID()
        return try await withTaskCancellationHandler {
            let result: Data = try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else { continuation.resume(throwing: CancellationError()); return }
                if var flight = inFlight[key] {
                    flight.waiters[waiter] = continuation
                    inFlight[key] = flight
                    return
                }
                let token = UUID()
                let task = Task {
                    do { finish(key, token: token, result: .success(try await download(url: url, server: server))) }
                    catch { finish(key, token: token, result: .failure(error)) }
                }
                inFlight[key] = Flight(id: token, task: task, waiters: [waiter: continuation])
            }
            try Task.checkCancellation()
            return result
        } onCancel: { Task { await self.cancel(key, waiter: waiter) } }
    }

    private func download(url: URL, server: BooruServer) async throws -> Data {
        try Task.checkCancellation()
        let data: Data
        if let loadData { data = try await loadData(url, server) }
        else {
            let request = await BooruBrowserSession.prepare(URLRequest(url: url), server: server)
            try Task.checkCancellation()
            do {
                let (file, response) = try await session.download(for: request)
                defer { try? FileManager.default.removeItem(at: file) }
                try Task.checkCancellation()
                guard let http = response as? HTTPURLResponse,
                      (try file.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0 <= 128 * 1024 * 1024 else { throw BooruError.invalidResponse }
                let downloaded = try Data(contentsOf: file, options: .mappedIfSafe)
                guard (200..<300).contains(http.statusCode),
                      let image = CGImageSourceCreateWithData(downloaded as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
                      CGImageSourceGetCount(image) > 0 else {
                    if let restriction = BooruPostAccessError.detect(downloaded, server: server) { throw restriction }
                    throw BooruError.invalidResponse
                }
                try Task.checkCancellation()
                return downloaded
            } catch {
                try Task.checkCancellation()
                if error as? BooruPostAccessError == .goldRequired { throw error }
                guard await BooruWebTransport.hasSession(for: server) else { throw error }
                data = try await BooruWebTransport.imageData(url: url, server: server)
            }
        }
        try Task.checkCancellation()
        guard data.count <= 128 * 1024 * 1024,
              let image = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(image) > 0 else {
            if let restriction = BooruPostAccessError.detect(data, server: server) { throw restriction }
            throw BooruError.invalidResponse
        }
        return data
    }

    private func cancel(_ key: String, waiter: UUID) {
        guard var flight = inFlight[key], let continuation = flight.waiters.removeValue(forKey: waiter) else { return }
        if flight.waiters.isEmpty { inFlight.removeValue(forKey: key); flight.task.cancel() }
        else { inFlight[key] = flight }
        continuation.resume(throwing: CancellationError())
    }

    private func finish(_ key: String, token: UUID, result: Result<Data, Error>) {
        guard let flight = inFlight[key], flight.id == token else { return }
        inFlight.removeValue(forKey: key)
        if case .success(let data) = result { disk.write(data, key: key) }
        for waiter in flight.waiters.values { waiter.resume(with: result) }
    }

    #if DEBUG
    func consumerCount(url: URL, server: BooruServer) -> Int {
        inFlight[server.canonicalAddress + ":" + server.id + ":" + url.absoluteString]?.waiters.count ?? 0
    }
    #endif

    func prefetch(url: URL, server: BooruServer) async {
        let key = server.canonicalAddress + ":" + server.id + ":" + url.absoluteString
        // Already saved originals need no read/parse just to warm the disk cache.
        guard !disk.contains(key), !Task.isCancelled else { return }
        _ = try? await data(url: url, server: server)
    }
}
