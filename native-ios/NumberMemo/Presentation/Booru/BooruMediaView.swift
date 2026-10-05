import SwiftUI
import WebKit
import ImageIO

actor BooruThumbnailCache {
    static let shared = BooruThumbnailCache()
    private let cache = NSCache<NSString, UIImage>()
    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        return URLSession(configuration: config, delegate: BooruRedirectPolicy(publicMedia: true), delegateQueue: nil)
    }()
    func clear() { cache.removeAllObjects() }
    init() { cache.totalCostLimit = 32 * 1024 * 1024 }
    private func cacheKey(_ url: URL, _ server: BooruServer) -> NSString { (server.id + ":" + url.absoluteString) as NSString }
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
        guard let url = post.fileURL ?? post.displayURL else { throw BooruError.invalidResponse }
        let (source, file) = try await imageSource(url, server: server)
        defer { if let file { try? FileManager.default.removeItem(at: file) } }
        return try ReaderTranslationImage.decode(source: source, rect: rect)
    }
    func image(url: URL, server: BooruServer) async throws -> UIImage {
        if let image = cache.object(forKey: cacheKey(url, server)) { return image }
        let (source, file) = try await imageSource(url, server: server)
        defer { if let file { try? FileManager.default.removeItem(at: file) } }
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceThumbnailMaxPixelSize: 600, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) else { throw BooruError.invalidResponse }
        let image = UIImage(cgImage: cgImage)
        cache.setObject(image, forKey: cacheKey(url, server), cost: cgImage.bytesPerRow * cgImage.height)
        return image
    }

    private func imageSource(_ url: URL, server: BooruServer) async throws -> (CGImageSource, URL?) {
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
        }.onReceive(NotificationCenter.default.publisher(for: .booruClientValidated)) { if $0.object as? String == server.id { retry += 1 } }
        .task(id: "\(post.id):\(post.previewURL?.absoluteString ?? post.sampleURL?.absoluteString ?? ""):\(retry)") {
            image = nil; failed = false
            guard !isFixture, let url = post.previewURL ?? post.sampleURL else { failed = true; return }
            do { image = try await BooruThumbnailCache.shared.image(url: url, server: server) }
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
    case tap(CGFloat), hold, swipe(Int), dismiss, zoom(Bool), viewport(CGRect)
}

struct BooruMediaView: UIViewRepresentable {
    let post: BooruPost
    let server: BooruServer
    let original: Bool
    let notes: [BooruNote]
    let showNotes: Bool
    let onNote: (BooruNote) -> Void
    let onStatus: (String) -> Void
    let onGesture: (BooruMediaGesture) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = BooruBrowserSession.dataStore(for: server)
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.setURLSchemeHandler(context.coordinator.resources, forURLScheme: "numbermemo-image")
        config.userContentController.add(context.coordinator, name: "media")
        let view = WKWebView(frame: .zero, configuration: config)
        view.customUserAgent = BooruBrowserSession.userAgent
        view.isOpaque = false; view.backgroundColor = .black; view.scrollView.backgroundColor = .black
        view.navigationDelegate = context.coordinator
        view.scrollView.bounces = false
        view.scrollView.contentInsetAdjustmentBehavior = .never
        view.scrollView.showsVerticalScrollIndicator = false
        view.scrollView.showsHorizontalScrollIndicator = false
        view.accessibilityIdentifier = "booru.media"
        return view
    }
    func updateUIView(_ view: WKWebView, context: Context) {
        let coordinator = context.coordinator
        coordinator.onNote = onNote; coordinator.onStatus = onStatus; coordinator.notes = notes
        coordinator.showNotes = showNotes
        coordinator.onGesture = onGesture
        let url = post.isVideo || post.isAnimated || original ? post.fileURL ?? post.displayURL : post.displayURL
        let key = post.id + ":" + (url?.absoluteString ?? "")
        if coordinator.key != key {
            coordinator.key = key
            coordinator.ready = false
            coordinator.width = max(post.width, 1); coordinator.height = max(post.height, 1)
            var displayURL = url
            if server.isGelbooruWebsite, !post.isVideo, let url, url.scheme == "https" {
                coordinator.resources.source = url; coordinator.resources.server = server
                displayURL = URL(string: "numbermemo-image://media/" + UUID().uuidString)
            }
            view.loadHTMLString(Self.document(post: post, url: displayURL), baseURL: server.baseURL)
        } else { coordinator.updateNotes(view) }
    }
    static func dismantleUIView(_ view: WKWebView, coordinator: Coordinator) {
        view.stopLoading()
        coordinator.resources.cancel()
        view.configuration.userContentController.removeScriptMessageHandler(forName: "media")
        view.loadHTMLString("", baseURL: nil)
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }
    private static func document(post: BooruPost, url: URL?) -> String {
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
        let media = isVideo
            ? "<video id='media' src='\(escape(source))' controls playsinline autoplay muted preload='auto'></video>"
            : "<img id='media' src='\(escape(source))' alt='Post \(post.postID)' />"
        let nonce = UUID().uuidString
        return """
        <!doctype html><html><head><meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=8, user-scalable=yes">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src https: data: numbermemo-image:; media-src https: blob: data:; style-src 'unsafe-inline'; script-src 'nonce-\(nonce)'; base-uri 'none'; form-action 'none'">
        <meta name="referrer" content="origin"><style>
        html,body{margin:0;width:100%;height:100%;background:#000;color:white;-webkit-touch-callout:none;-webkit-user-select:none}body{display:flex;align-items:center;justify-content:center}
        #canvas{position:relative;flex:none}#media{display:block;width:100%;height:100%;object-fit:contain}
        #notes{position:absolute;inset:0;pointer-events:none}.note{position:absolute;box-sizing:border-box;border:2px solid #ffd45a;background:#ffd45a30;color:white;pointer-events:auto;padding:0;min-width:18px;min-height:18px;text-align:left}
        .note span{background:#202020dd;padding:2px 5px;font:12px -apple-system;border-radius:4px}
        </style></head><body><div id="canvas">\(media)<div id="notes"></div></div>
        <script nonce="\(nonce)">
        const media=document.getElementById('media');
        const send=value=>window.webkit.messageHandlers.media.postMessage(value);
        const fit=()=>{const w=media.naturalWidth||media.videoWidth||\(max(post.width, 1));const h=media.naturalHeight||media.videoHeight||\(max(post.height, 1));
          const scale=Math.min(innerWidth/w,innerHeight/h);const canvas=document.getElementById('canvas');canvas.style.width=(w*scale)+'px';canvas.style.height=(h*scale)+'px';};
        let retries=0;
        media.addEventListener('error',()=>{
          if(retries>=2){send({status:'error'});return;}
          retries++;send({status:'loading'});
          setTimeout(()=>{const url=media.getAttribute('src');media.removeAttribute('src');media.setAttribute('src',url);
            if(media.tagName==='VIDEO')media.load();},retries*500);
        });
        media.addEventListener('load',()=>{fit();send({status:'ready'});});
        media.addEventListener('loadedmetadata',()=>{fit();send({status:'ready'});});
        media.addEventListener('playing',()=>send({status:'playing'}));
        media.addEventListener('ended',()=>send({status:'ended'}));
        if(media.tagName==='VIDEO')send({status:'waiting'});
        window.addEventListener('resize',fit);fit();
        let start=null,holdTimer=null,tapTimer=null,lastTap=0,held=false;
        const zoom=()=>window.visualViewport?.scale||1;
        const viewport=()=>{const r=media.getBoundingClientRect(),v=window.visualViewport;
          if(!r.width||!r.height)return;
          const left=v?.offsetLeft||0,top=v?.offsetTop||0,right=left+(v?.width||innerWidth),bottom=top+(v?.height||innerHeight);
          const x=Math.max(0,(left-r.left)/r.width),y=Math.max(0,(top-r.top)/r.height);
          send({viewport:{x:x,y:y,w:Math.max(0,Math.min(1,(right-r.left)/r.width)-x),h:Math.max(0,Math.min(1,(bottom-r.top)/r.height)-y)}});
        };
        media.addEventListener('load',viewport);
        window.visualViewport?.addEventListener('resize',()=>{send({scale:zoom()});viewport();});
        window.visualViewport?.addEventListener('scroll',viewport);
        window.addEventListener('scroll',viewport);
        const cancelHold=()=>{clearTimeout(holdTimer);holdTimer=null;};
        document.addEventListener('touchstart',e=>{
          cancelHold();held=false;
          if(e.touches.length!==1||e.target.closest('button')){start=null;return;}
          const t=e.touches[0],video=!!e.target.closest('video');
          if(video&&t.clientY>media.getBoundingClientRect().bottom-56){start=null;return;}
          start={x:t.clientX,y:t.clientY,time:Date.now(),zoom:zoom(),video:video};
          holdTimer=setTimeout(()=>{if(start&&start.x/innerWidth>=0.3&&start.x/innerWidth<=0.7){held=true;send({gesture:'hold'});}},550);
        },{passive:true});
        document.addEventListener('touchmove',e=>{
          if(!start)return;
          if(e.touches.length!==1){start=null;cancelHold();return;}
          const t=e.touches[0];if(Math.hypot(t.clientX-start.x,t.clientY-start.y)>10)cancelHold();
          if(start.zoom<=1.01&&zoom()<=1.01)e.preventDefault();
        },{passive:false});
        document.addEventListener('touchcancel',()=>{start=null;cancelHold();},{passive:true});
        document.addEventListener('touchend',e=>{
          cancelHold();if(!start)return;
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
        window.renderNotes=(notes,visible)=>{const layer=document.getElementById('notes');layer.replaceChildren();layer.hidden=!visible;
          notes.forEach((note,index)=>{const b=document.createElement('button');b.className='note';b.setAttribute('aria-label','Note '+(index+1));
          b.style.left=note.x+'%';b.style.top=note.y+'%';b.style.width=note.w+'%';b.style.height=note.h+'%';
          const label=document.createElement('span');label.textContent=index+1;b.appendChild(label);b.onclick=()=>send({note:index});layer.appendChild(b);});};
        </script></body></html>
        """
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        let resources = BooruImageResourceHandler()
        var key = ""
        var ready = false
        var width = 1
        var height = 1
        var notes: [BooruNote] = []
        var showNotes = false
        var onNote: ((BooruNote) -> Void)?
        var onStatus: ((String) -> Void)?
        var onGesture: ((BooruMediaGesture) -> Void)?
        func updateNotes(_ view: WKWebView) {
            guard ready else { return }
            let values = notes.map { note -> [String: Double] in
                ["x": max(0, min(100, note.x / Double(width) * 100)), "y": max(0, min(100, note.y / Double(height) * 100)),
                 "w": max(0, min(100, note.width / Double(width) * 100)), "h": max(0, min(100, note.height / Double(height) * 100))]
            }
            guard let data = try? JSONSerialization.data(withJSONObject: values), let json = String(data: data, encoding: .utf8) else { return }
            view.evaluateJavaScript("window.renderNotes(\(json), \(showNotes ? "true" : "false"));", completionHandler: nil)
        }
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.frameInfo.isMainFrame, let value = message.body as? [String: Any] else { return }
            if let index = value["note"] as? Int, notes.indices.contains(index) { onNote?(notes[index]) }
            if let status = value["status"] as? String { onStatus?(status) }
            if let rect = value["viewport"] as? [String: Double], let x = rect["x"], let y = rect["y"], let w = rect["w"], let h = rect["h"], w > 0, h > 0 {
                onGesture?(.viewport(CGRect(x: x, y: y, width: w, height: h)))
            }
            if let scale = value["scale"] as? Double { onGesture?(.zoom(scale > 1.01)) }
            switch value["gesture"] as? String {
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
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { ready = true; updateNotes(webView) }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { onStatus?("error") }
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { onStatus?("error") }
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
    private var pending: [ObjectIdentifier: Task<Void, Never>] = [:]
    private let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.timeoutIntervalForRequest = 25
        configuration.timeoutIntervalForResource = 60
        return URLSession(configuration: configuration, delegate: BooruRedirectPolicy(publicMedia: true), delegateQueue: nil)
    }()
    func cancel() {
        for task in pending.values { task.cancel() }
        pending.removeAll()
        session.invalidateAndCancel()
    }
    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        let id = ObjectIdentifier(urlSchemeTask)
        guard let source, let server, let localURL = urlSchemeTask.request.url else {
            urlSchemeTask.didFailWithError(BooruError.invalidResponse); return
        }
        pending[id] = Task {
            defer { pending[id] = nil }
            do {
                let request = await BooruBrowserSession.prepare(URLRequest(url: source), server: server)
                let (file, response) = try await session.download(for: request)
                defer { try? FileManager.default.removeItem(at: file) }
                try Task.checkCancellation()
                guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                      let mime = response.mimeType, mime.hasPrefix("image/"),
                      let image = CGImageSourceCreateWithURL(file as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
                      CGImageSourceGetCount(image) > 0 else { throw BooruError.invalidResponse }
                let size = (try file.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0
                guard size <= 128 * 1024 * 1024 else { throw BooruError.invalidResponse }
                let handle = try FileHandle(forReadingFrom: file)
                defer { try? handle.close() }
                urlSchemeTask.didReceive(URLResponse(url: localURL, mimeType: mime, expectedContentLength: size, textEncodingName: nil))
                while let chunk = try handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
                    try Task.checkCancellation()
                    urlSchemeTask.didReceive(chunk)
                    await Task.yield()
                }
                try Task.checkCancellation()
                urlSchemeTask.didFinish()
            } catch {
                if !Task.isCancelled { urlSchemeTask.didFailWithError(error) }
            }
        }
    }
    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {
        pending.removeValue(forKey: ObjectIdentifier(urlSchemeTask))?.cancel()
    }
}
