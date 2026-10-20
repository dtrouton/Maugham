import AppKit
import ImageIO
import MaughamCore

// A thumbnail of the image beneath each figure line in the manuscript editor
// (report foundations plan 3a, Task 7).
//
// It is a DECORATION, never an attachment: the text storage stays plain text
// (tripwires 1, 26). The room comes from the figure line's `paragraphSpacing`
// (`ProseMode.reservesFigureThumbnails`, a text-derived attribute, so the
// windowed and whole-document paints agree); the picture is drawn into that
// gap by `FigureThumbnailOverlay`, a click-through view over the text view on
// the `AnnotationMarkRenderer` pattern. Images resolve through
// `FigureImageResolver` from the document's own path, decode off the main
// thread with ImageIO thumbnailing (never a full decode), and are cached by
// (resolved path, modification date) in a small LRU (tripwire 4).
//
// Only the manuscript editor shows thumbnails: `EditorHost` is the one host
// that sets both the resolver and the mode's reserved space. A research note
// and a statement share `ProseMode` but neither, so they draw nothing and
// reserve nothing.

// MARK: - Layout (pure)

enum FigureThumbnailLayout {
    /// The tallest a thumbnail is drawn. It also fits the column width.
    static let maxHeight: CGFloat = 120
    /// The space above and below a thumbnail, inside the reserved gap.
    static let gap: CGFloat = 6
    /// The "Image not found" box: smaller than a thumbnail, in the same gap.
    static let placeholderHeight: CGFloat = 28
    static let placeholderWidth: CGFloat = 160
    /// The extra `paragraphSpacing` a figure line's paragraph carries. Fixed,
    /// whatever the picture's shape: it is derived from the text alone, so a
    /// decode landing never re-lays out the document.
    static var reservedHeight: CGFloat { maxHeight + 2 * gap }

    enum Content: Equatable {
        case image(natural: CGSize)
        case placeholder
    }

    /// One figure line: its range (without the newline) and its path as written.
    struct Mark: Equatable {
        let lineRange: NSRange
        let path: String
    }

    /// The path written in a figure line's `](path)` token, or nil when
    /// `token` is not that closing token. The opening `![` is a separate
    /// `.figureSyntax` token; keying both the spacing and the thumbnail on the
    /// closing one keeps them on exactly the same lines.
    static func figurePath(closing token: Token, in text: NSString) -> String? {
        guard case .figureSyntax = token.kind, token.range.length >= 3,
              NSMaxRange(token.range) <= text.length,
              text.character(at: token.range.location) == closeBracket,
              text.character(at: token.range.location + 1) == openParen,
              text.character(at: NSMaxRange(token.range) - 1) == closeParen
        else { return nil }
        return text.substring(with: NSRange(location: token.range.location + 2,
                                            length: token.range.length - 3))
    }

    /// Every figure line in `tokens`, in document order.
    static func marks(in tokens: [Token], text: NSString) -> [Mark] {
        var out: [Mark] = []
        for token in tokens {
            guard let path = figurePath(closing: token, in: text) else { continue }
            var start = 0, end = 0, contentsEnd = 0
            text.getLineStart(&start, end: &end, contentsEnd: &contentsEnd,
                              for: NSRange(location: token.range.location, length: 0))
            out.append(Mark(lineRange: NSRange(location: start, length: contentsEnd - start),
                            path: path))
        }
        return out.sorted { $0.lineRange.location < $1.lineRange.location }
    }

    /// The marks whose line intersects `window`, found by binary search over
    /// the sorted, non-overlapping `marks`.
    static func marks(_ marks: [Mark], intersecting window: NSRange) -> [Mark] {
        guard window.length > 0 else { return [] }
        var lo = 0, hi = marks.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if NSMaxRange(marks[mid].lineRange) <= window.location { lo = mid + 1 } else { hi = mid }
        }
        var out: [Mark] = []
        var i = lo
        while i < marks.count, marks[i].lineRange.location < NSMaxRange(window) {
            if NSIntersectionRange(marks[i].lineRange, window).length > 0 { out.append(marks[i]) }
            i += 1
        }
        return out
    }

    /// `natural` scaled to fit `columnWidth` × `maxHeight`, keeping its shape,
    /// never enlarged, in whole points.
    static func fittedSize(natural: CGSize, columnWidth: CGFloat) -> CGSize {
        guard natural.width > 0, natural.height > 0, columnWidth > 0 else { return .zero }
        let scale = min(1, columnWidth / natural.width, maxHeight / natural.height)
        return CGSize(width: (natural.width * scale).rounded(),
                      height: (natural.height * scale).rounded())
    }

    /// Where `content` is drawn: at the column's left edge, `gap` below the
    /// bottom of the figure line's last line fragment.
    static func frame(for content: Content, lineBottom: CGFloat,
                      columnX: CGFloat, columnWidth: CGFloat) -> CGRect {
        let origin = CGPoint(x: columnX, y: lineBottom + gap)
        switch content {
        case .image(let natural):
            return CGRect(origin: origin, size: fittedSize(natural: natural, columnWidth: columnWidth))
        case .placeholder:
            return CGRect(origin: origin, size: CGSize(width: min(placeholderWidth, max(0, columnWidth)),
                                                       height: placeholderHeight))
        }
    }

    /// The pixel size to decode at: the larger side a thumbnail can be drawn
    /// at in this column, on this screen.
    static func maxPixelSize(columnWidth: CGFloat, backingScale: CGFloat) -> Int {
        Int((max(columnWidth, maxHeight) * max(1, backingScale)).rounded(.up))
    }
}

private let closeBracket = unichar(UInt8(ascii: "]"))
private let openParen = unichar(UInt8(ascii: "("))
private let closeParen = unichar(UInt8(ascii: ")"))

// MARK: - The cache

/// A decoded image's identity: the RESOLVED file (so two spellings of one
/// path share an entry) and its modification date (so a re-saved image is a
/// new entry).
struct FigureThumbnailKey: Hashable, Sendable {
    let path: String
    let modified: Date?
}

/// A small least-recently-used cache. Main-thread only (the store's).
final class FigureThumbnailCache<Value> {
    let capacity: Int
    private var values: [FigureThumbnailKey: Value] = [:]
    /// Least recently used first.
    private var order: [FigureThumbnailKey] = []

    init(capacity: Int) { self.capacity = max(1, capacity) }

    var count: Int { values.count }

    func value(for key: FigureThumbnailKey) -> Value? {
        guard let value = values[key] else { return nil }
        touch(key)
        return value
    }

    func insert(_ value: Value, for key: FigureThumbnailKey) {
        values[key] = value
        touch(key)
        while order.count > capacity { values[order.removeFirst()] = nil }
    }

    private func touch(_ key: FigureThumbnailKey) {
        order.removeAll { $0 == key }
        order.append(key)
    }
}

// MARK: - The store

/// What each figure path resolves to, and its decoded thumbnail. `thumbnail`
/// never blocks: it answers what is known and, when nothing is or the answer
/// is a couple of seconds old, starts a background check (resolve + stat),
/// then a decode only when the (resolved path, modification date) is not
/// cached. `onUpdate` fires only when an answer CHANGES, so a re-check that
/// finds the same file never redraws.
@MainActor
final class FigureThumbnailStore {
    typealias Resolve = @Sendable (String) -> FigureImageResolver.Outcome

    enum Thumbnail {
        case image(CGImage, natural: CGSize)
        /// Drawn as the small muted box, with this message.
        case unshowable(String)

        var message: String? {
            if case .unshowable(let message) = self { return message }
            return nil
        }
    }

    nonisolated static let cacheCapacity = 16
    nonisolated static let notFoundMessage = "Image not found"
    nonisolated static let svgMessage = "SVG not shown"
    /// How stale an answer may be before the next draw re-checks the disk (a
    /// replaced image, a file that has since appeared).
    nonisolated static let recheckInterval: TimeInterval = 2
    /// Every extension the editor tries; a figure format the resolver would
    /// otherwise refuse by extension still gets the not-found box, not silence.
    nonisolated static let triedExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "pdf", "svg", "heic", "heif", "tif", "tiff",
        "webp", "bmp",
    ]
    private static let knownLimit = 64

    var onUpdate: (() -> Void)?
    /// How many decodes ran (tests: one file under two spellings decodes once).
    private(set) var decodeCount = 0

    private let resolve: Resolve
    private let now: () -> Date
    private let cache = FigureThumbnailCache<Thumbnail>(capacity: FigureThumbnailStore.cacheCapacity)
    private var known: [String: Known] = [:]
    private var work: [String: Task<Void, Never>] = [:]

    private struct Known {
        var thumbnail: Thumbnail
        var key: FigureThumbnailKey?
        var checkedAt: Date
    }

    init(resolve: @escaping Resolve, now: @escaping () -> Date = Date.init) {
        self.resolve = resolve
        self.now = now
    }

    func thumbnail(for path: String, maxPixelSize: Int) -> Thumbnail? {
        let entry = known[path]
        let stale = entry.map { now().timeIntervalSince($0.checkedAt) >= Self.recheckInterval } ?? true
        if stale, work[path] == nil { start(path, maxPixelSize: maxPixelSize) }
        return entry?.thumbnail
    }

    /// The check or decode running for `path`, so a test can await it.
    func pendingWork(for path: String) -> Task<Void, Never>? { work[path] }

    private func start(_ path: String, maxPixelSize: Int) {
        let resolve = self.resolve
        work[path] = Task { [weak self] in
            let found = await Task.detached(priority: .utility) {
                Self.locate(path, resolve: resolve)
            }.value
            await self?.finish(path, found: found, maxPixelSize: maxPixelSize)
        }
    }

    private func finish(_ path: String, found: Located, maxPixelSize: Int) async {
        defer { work[path] = nil }
        switch found {
        case .notShown(let message):
            record(path, .unshowable(message), key: nil)
        case .file(let key, let url):
            if let cached = cache.value(for: key) {
                record(path, cached, key: key)
                return
            }
            decodeCount += 1
            let decoded = await Task.detached(priority: .utility) {
                Self.decode(url, maxPixelSize: maxPixelSize)
            }.value
            let thumbnail = decoded.map { Thumbnail.image($0.image, natural: $0.natural) }
                ?? .unshowable(Self.notFoundMessage)
            cache.insert(thumbnail, for: key)
            record(path, thumbnail, key: key)
        }
    }

    private func record(_ path: String, _ thumbnail: Thumbnail, key: FigureThumbnailKey?) {
        let previous = known[path]
        known[path] = Known(thumbnail: thumbnail, key: key, checkedAt: now())
        trimKnown()
        let changed = previous == nil || previous?.key != key
            || previous?.thumbnail.message != thumbnail.message
        if changed { onUpdate?() }
    }

    /// Typing a path makes an entry per prefix; keep the newest few.
    private func trimKnown() {
        guard known.count > Self.knownLimit else { return }
        let oldest = known.sorted { $0.value.checkedAt < $1.value.checkedAt }
            .prefix(known.count - Self.knownLimit)
        for (path, _) in oldest where work[path] == nil { known[path] = nil }
    }

    // MARK: Off the main thread

    private enum Located: Sendable {
        case file(FigureThumbnailKey, URL)
        case notShown(String)
    }

    /// The resolver's answer plus the file's modification date: a stat, never
    /// a read.
    nonisolated private static func locate(_ path: String, resolve: Resolve) -> Located {
        switch resolve(path) {
        case .file(let url):
            if url.pathExtension.lowercased() == "svg" { return .notShown(svgMessage) }
            let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate
            return .file(FigureThumbnailKey(path: url.path, modified: modified), url)
        case .notLocal, .unreadable:
            return .notShown(notFoundMessage)
        }
    }

    struct Decoded: @unchecked Sendable {   // CGImage is immutable
        let image: CGImage
        let natural: CGSize
    }

    /// A thumbnail no larger than `maxPixelSize` on its longer side: ImageIO's
    /// thumbnailer for a raster (never a full decode), page 1 for a PDF.
    /// `natural` is the picture's own size in points (one pixel each, the way
    /// a browser shows an image; a PDF page's own size).
    nonisolated static func decode(_ url: URL, maxPixelSize: Int) -> Decoded? {
        if url.pathExtension.lowercased() == "pdf" { return decodePDF(url, maxPixelSize: maxPixelSize) }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetCount(source) > 0 else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { return nil }
        // The thumbnail is already oriented; scale its shape back up to the
        // original's longer side for the natural size.
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let w = (props?[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue ?? 0
        let h = (props?[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue ?? 0
        let longest = max(w, h)
        let thumbLongest = Double(max(image.width, image.height))
        let factor = longest > 0 && thumbLongest > 0 ? longest / thumbLongest : 1
        return Decoded(image: image,
                       natural: CGSize(width: (Double(image.width) * factor).rounded(),
                                       height: (Double(image.height) * factor).rounded()))
    }

    nonisolated private static func decodePDF(_ url: URL, maxPixelSize: Int) -> Decoded? {
        guard let document = CGPDFDocument(url as CFURL), !document.isEncrypted,
              let page = document.page(at: 1) else { return nil }
        let box = page.getBoxRect(.cropBox)
        guard box.width > 0, box.height > 0 else { return nil }
        let scale = min(1, CGFloat(maxPixelSize) / max(box.width, box.height))
        let width = max(1, Int((box.width * scale).rounded()))
        let height = max(1, Int((box.height * scale).rounded()))
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        // A page is paper: white under whatever it draws.
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: CGFloat(width) / box.width, y: CGFloat(height) / box.height)
        context.translateBy(x: -box.minX, y: -box.minY)
        context.drawPDFPage(page)
        guard let image = context.makeImage() else { return nil }
        return Decoded(image: image, natural: CGSize(width: box.width.rounded(),
                                                     height: box.height.rounded()))
    }
}

// MARK: - The overlay

/// Transparent, click-through overlay over the text view (installed as its
/// subview, like `AnnotationMarkRenderer`) that draws each visible figure
/// line's thumbnail into the gap its paragraph spacing left. It reads only
/// cached data per draw: the coordinator's figure marks and the store's
/// answers (tripwire 4).
final class FigureThumbnailOverlay: NSView {
    weak var coordinator: EditorCoordinator?
    weak var associatedTextView: NSTextView?
    /// How many figure lines the last draw found in view (the mounted test's
    /// reading; nothing is drawn for none).
    private(set) var lastVisibleFigureCount = 0

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }  // never intercept clicks

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observe()
    }
    deinit { NotificationCenter.default.removeObserver(self) }

    /// Repaint on a text change, on any storage edit (a restyle or the focus
    /// dim changes the alpha a thumbnail draws at), and on scroll.
    private func observe() {
        let nc = NotificationCenter.default
        nc.removeObserver(self)
        guard let textView = associatedTextView else { return }
        nc.addObserver(self, selector: #selector(repaint(_:)),
                       name: NSText.didChangeNotification, object: textView)
        if let storage = textView.textStorage {
            nc.addObserver(self, selector: #selector(repaint(_:)),
                           name: NSTextStorage.didProcessEditingNotification, object: storage)
        }
        if let clip = textView.enclosingScrollView?.contentView {
            clip.postsBoundsChangedNotifications = true
            nc.addObserver(self, selector: #selector(repaint(_:)),
                           name: NSView.boundsDidChangeNotification, object: clip)
        }
    }
    @objc private func repaint(_ note: Notification) { needsDisplay = true }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        lastVisibleFigureCount = 0
        guard let textView = associatedTextView,
              let layoutManager = textView.layoutManager,
              let container = textView.textContainer,
              let storage = textView.textStorage,
              let coordinator,
              let store = coordinator.figureThumbnailStore else { return }
        let marks = coordinator.figureThumbnailMarks
        guard !marks.isEmpty else { return }

        // The thumbnail hangs BELOW its line, so a line just above the view
        // can still show one: look a reserved gap higher than the view's top.
        let origin = textView.textContainerOrigin
        var probe = textView.visibleRect.offsetBy(dx: -origin.x, dy: -origin.y)
        probe.origin.y -= FigureThumbnailLayout.reservedHeight
        probe.size.height += FigureThumbnailLayout.reservedHeight
        let glyphs = layoutManager.glyphRange(forBoundingRect: probe, in: container)
        let chars = layoutManager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        let visible = FigureThumbnailLayout.marks(marks, intersecting: chars)
        lastVisibleFigureCount = visible.count
        guard !visible.isEmpty else { return }

        let padding = container.lineFragmentPadding
        let columnX = origin.x + padding
        let columnWidth = max(0, container.size.width - 2 * padding)
        let maxPixels = FigureThumbnailLayout.maxPixelSize(
            columnWidth: columnWidth, backingScale: window?.backingScaleFactor ?? 2)

        for mark in visible {
            guard mark.lineRange.length > 0, NSMaxRange(mark.lineRange) <= storage.length,
                  let thumbnail = store.thumbnail(for: mark.path, maxPixelSize: maxPixels)
            else { continue }
            let lastGlyph = layoutManager.glyphIndexForCharacter(at: NSMaxRange(mark.lineRange) - 1)
            let used = layoutManager.lineFragmentUsedRect(forGlyphAt: lastGlyph, effectiveRange: nil)
            let lineBottom = used.maxY + origin.y
            // The paragraph's alpha, so focus dimming dims the picture too.
            let alpha = (storage.attribute(.foregroundColor, at: mark.lineRange.location,
                                           effectiveRange: nil) as? NSColor)?.alphaComponent ?? 1
            switch thumbnail {
            case .image(let image, let natural):
                let frame = FigureThumbnailLayout.frame(
                    for: .image(natural: natural), lineBottom: lineBottom,
                    columnX: columnX, columnWidth: columnWidth)
                if frame.intersects(dirtyRect) { draw(image, in: frame, alpha: alpha) }
            case .unshowable(let message):
                let frame = FigureThumbnailLayout.frame(
                    for: .placeholder, lineBottom: lineBottom,
                    columnX: columnX, columnWidth: columnWidth)
                if frame.intersects(dirtyRect) { drawBox(message, in: frame, alpha: alpha) }
            }
        }
    }

    private func draw(_ image: CGImage, in frame: CGRect, alpha: CGFloat) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        // CGContext draws images bottom-up; this view is flipped.
        context.translateBy(x: frame.minX, y: frame.maxY)
        context.scaleBy(x: 1, y: -1)
        context.setAlpha(alpha)
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(origin: .zero, size: frame.size))
        context.restoreGState()
    }

    private func drawBox(_ message: String, in frame: CGRect, alpha: CGFloat) {
        let box = NSBezierPath(roundedRect: frame.insetBy(dx: 0.5, dy: 0.5), xRadius: 4, yRadius: 4)
        NSColor.secondaryLabelColor.withAlphaComponent(0.08 * alpha).setFill()
        box.fill()
        NSColor.separatorColor.withAlphaComponent(alpha).setStroke()
        box.lineWidth = 1
        box.stroke()
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: NSColor.secondaryLabelColor.withAlphaComponent(alpha),
        ]
        let text = message as NSString
        let size = text.size(withAttributes: attrs)
        text.draw(at: NSPoint(x: frame.minX + 8, y: frame.midY - size.height / 2),
                  withAttributes: attrs)
    }
}

// MARK: - The coordinator's side

extension EditorCoordinator {
    /// Whether this surface draws figure thumbnails: it has a resolver (only
    /// `EditorHost` builds one) and its mode reserves their space.
    var showsFigureThumbnails: Bool {
        figureImageResolver != nil
            && (mode as? ProseMode)?.reservesFigureThumbnails == true
    }

    /// Install the overlay (and its store) when this surface shows thumbnails.
    /// Idempotent; called from `attach`.
    func syncFigureThumbnailOverlay() {
        guard let textView, showsFigureThumbnails, let resolve = figureImageResolver else { return }
        if figureThumbnailStore == nil {
            let store = FigureThumbnailStore(resolve: resolve)
            // A decode landing repaints the overlay only, never the text.
            store.onUpdate = { [weak self] in self?.figureThumbnailOverlay?.needsDisplay = true }
            figureThumbnailStore = store
        }
        if figureThumbnailOverlay == nil {
            let overlay = FigureThumbnailOverlay(frame: textView.bounds)
            overlay.coordinator = self
            overlay.associatedTextView = textView
            overlay.autoresizingMask = [.width, .height]
            textView.addSubview(overlay)
            figureThumbnailOverlay = overlay
        }
        layoutFigureThumbnailOverlay(in: textView)
    }

    /// The overlay covers the text view. Re-framed on resize from
    /// `MaughamTextView.updateColumnInset`, like the review overlays.
    func layoutFigureThumbnailOverlay(in textView: NSTextView) {
        guard let overlay = figureThumbnailOverlay else { return }
        overlay.frame = textView.bounds
        overlay.needsDisplay = true
    }

    /// The figure lines in `lastTokens`, derived once per retokenize.
    var figureThumbnailMarks: [FigureThumbnailLayout.Mark] {
        if let cached = figureThumbnailMarksCache { return cached }
        guard showsFigureThumbnails, let textView else { return [] }
        let marks = FigureThumbnailLayout.marks(in: lastTokens, text: textView.string as NSString)
        figureThumbnailMarksCache = marks
        return marks
    }
}
