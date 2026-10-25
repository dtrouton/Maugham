import AppKit
import ImageIO
import MaughamCore

// A thumbnail of the image beneath each figure line in the manuscript editor
// (report foundations plan 3a, Task 7).
//
// It is a DECORATION, never an attachment: the text storage stays plain text
// (tripwires 1, 26). The room comes from the figure line's `paragraphSpacing`
// (`ProseMode.reservesFigureThumbnails`; both paints read one function of the
// line's path, `figureRoom(forLinePath:)`, so they agree); the picture is drawn into that
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

    /// The path written on `text`'s last line when it is a figure line with
    /// no newline after it — the case TextKit 1 lays out no paragraph spacing
    /// for (whole-branch review I1) — else nil. Read from the TEXT, never
    /// from tokens or marks: AppKit re-sizes the text view while an edit is
    /// landing, before the retokenize, when anything token-derived still
    /// describes the text before the edit.
    ///
    /// The last line's blank-line block (the unit the tokenizer reads,
    /// `BlankLineBlocks`) goes through `ManuscriptBlocks.parse`, the rule the
    /// tokenizer's figure tokens come from. O(the last paragraph), behind a
    /// cheap `![` gate on the last line.
    static func trailingFigurePath(_ text: NSString) -> String? {
        let length = text.length
        guard length > 0 else { return nil }
        let lastCharacter = text.character(at: length - 1)
        guard lastCharacter != 0x0A, lastCharacter != 0x0D else { return nil }
        let lastLineStart = text.lineRange(for: NSRange(location: length - 1, length: 0)).location
        guard text.range(of: "![", options: .literal,
                         range: NSRange(location: lastLineStart, length: length - lastLineStart)
        ).location != NSNotFound else { return nil }
        var blockStart = lastLineStart
        while blockStart > 0 {
            let previous = text.lineRange(for: NSRange(location: blockStart - 1, length: 0))
            if text.substring(with: previous).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                break
            }
            blockStart = previous.location
        }
        let block = text.substring(with: NSRange(location: blockStart, length: length - blockStart))
        guard let last = ManuscriptBlocks.parse(block).last,
              case .figure(_, let path, _) = last.block else { return nil }
        return path
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

    /// The pixel size to decode at: the longer side of the size this picture
    /// is actually drawn at (`fittedSize`, known from its header before any
    /// decode), on this screen. A portrait page held to 120 pt decodes at
    /// 240 px on a Retina screen, not at the column's width.
    static func decodePixelSize(natural: CGSize, columnWidth: CGFloat,
                                backingScale: CGFloat) -> Int {
        let fitted = fittedSize(natural: natural, columnWidth: columnWidth)
        return max(1, Int((max(fitted.width, fitted.height) * max(1, backingScale)).rounded(.up)))
    }
}

private let closeBracket = unichar(UInt8(ascii: "]"))
private let openParen = unichar(UInt8(ascii: "("))
private let closeParen = unichar(UInt8(ascii: ")"))

// MARK: - The table card's metrics (pure)

/// **The one place the editor turns a table figure's cached card into room**
/// (report plan 7a Task 4): the card's row metrics, derived from the editor's
/// typography, and the `paragraphSpacing` its figure line reserves
/// (`ProseMode.reserveFigureThumbnailSpace`, through the coordinator's
/// `figureRoom(forLinePath:)`). The card overlay (Task 6) draws with these
/// same metrics, so what it draws fits the room the text left.
///
/// A pure function of (model, typography): the windowed and whole-document
/// paints agree, and nothing here reads the disk or the op log.
enum FigureCardMetrics {
    /// The card's text is the body size scaled by this, rounded to a point.
    static let fontScale: CGFloat = 0.8
    /// The space above and below each row's text, inside the row.
    static let rowInset: CGFloat = 3

    /// The card's font: the system font at `fontScale` of the body size.
    static func font(for typography: TypographySettings) -> NSFont {
        NSFont.systemFont(ofSize: (CGFloat(typography.fontSize) * fontScale).rounded())
    }

    /// One row: the card font's line height, rounded up, plus `rowInset`
    /// above and below. The "+ N more rows" line is one row tall.
    static func rowHeight(for typography: TypographySettings) -> CGFloat {
        let font = font(for: typography)
        return (font.ascender - font.descender + font.leading).rounded(.up) + 2 * rowInset
    }

    /// The card's padding above its first row and below its last, the
    /// thumbnail's gap.
    static var verticalPadding: CGFloat { FigureThumbnailLayout.gap }

    /// **The room a figure line reserves**: a table card's height from its
    /// model (`FigureCardLayout.height`), or `FigureThumbnailLayout.reservedHeight`
    /// for an image, a labelled card (removed, ambiguous, parked; ruling
    /// R7a-3) and a cache miss (`nil`, the placeholder until the fill lands;
    /// ruling R7a-2). Rows are one line each, so the column width does not
    /// enter the height (`FigureCardLayout`); passing none keeps the room
    /// independent of the window's width.
    static func room(for model: FigureCardModel?, typography: TypographySettings) -> CGFloat {
        guard let model else { return FigureThumbnailLayout.reservedHeight }
        let row = rowHeight(for: typography)
        return FigureCardLayout.height(
            for: model, columnWidth: 0,
            rowHeight: row, moreLineHeight: row, verticalPadding: verticalPadding,
            placeholderHeight: FigureThumbnailLayout.reservedHeight)
    }

    /// The tallest room any figure line reserves: a capped card and its
    /// "more" line, or the thumbnail's. How far above the view the overlay
    /// looks for a line whose card hangs into it.
    static func maxRoom(typography: TypographySettings) -> CGFloat {
        let row = rowHeight(for: typography)
        return max(FigureThumbnailLayout.reservedHeight,
                   CGFloat(FigureCardModel.maxShownRows + 1) * row + 2 * verticalPadding)
    }
}

// MARK: - The cache

/// A decoded image's identity: the RESOLVED file (so two spellings of one
/// path share an entry), its modification date (so a re-saved image is a
/// new entry) and the column's decode bucket (so a widened column, or a
/// Retina screen, decodes again rather than upscaling a small decode —
/// whole-branch review M4).
struct FigureThumbnailKey: Hashable, Sendable {
    let path: String
    let modified: Date?
    var bucket: Int = 0

    /// The column's width in device pixels, in steps of `bucketPixels`: a
    /// window dragged a few points wider decodes nothing new.
    static let bucketPixels: CGFloat = 64
    static func bucket(columnWidth: CGFloat, backingScale: CGFloat) -> Int {
        Int((max(0, columnWidth) * max(1, backingScale) / bucketPixels).rounded(.up))
    }
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

    /// Whether `path` names a table figure's render (`figures/<name>.csv`):
    /// the store never resolves or decodes one (report plan 7a Task 6).
    nonisolated static func isTableRender(_ path: String) -> Bool {
        (path as NSString).pathExtension.lowercased() == "csv"
    }

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

    /// - Parameters:
    ///   - columnWidth: the column a thumbnail is fitted to.
    ///   - backingScale: the screen's, so the decode is sharp and no larger.
    func thumbnail(for path: String, columnWidth: CGFloat, backingScale: CGFloat) -> Thumbnail? {
        // A table's render is not a picture: its card draws it, and until the
        // card is filled the line shows nothing, never "Image not found".
        guard !Self.isTableRender(path) else { return nil }
        let entry = known[path]
        let bucket = FigureThumbnailKey.bucket(columnWidth: columnWidth, backingScale: backingScale)
        let stale = entry.map {
            now().timeIntervalSince($0.checkedAt) >= Self.recheckInterval
                || ($0.key.map { $0.bucket != bucket } ?? false)
        } ?? true
        if stale, work[path] == nil {
            start(path, columnWidth: columnWidth, backingScale: backingScale)
        }
        return entry?.thumbnail
    }

    /// The check or decode running for `path`, so a test can await it.
    func pendingWork(for path: String) -> Task<Void, Never>? { work[path] }

    /// Stops every check and decode in flight and tells no one (the editor is
    /// going away: `EditorCoordinator.detach`).
    func cancelAll() {
        onUpdate = nil
        work.values.forEach { $0.cancel() }
        work.removeAll()
    }

    private func start(_ path: String, columnWidth: CGFloat, backingScale: CGFloat) {
        let resolve = self.resolve
        let bucket = FigureThumbnailKey.bucket(columnWidth: columnWidth, backingScale: backingScale)
        work[path] = Task { [weak self] in
            let found = await Task.detached(priority: .utility) {
                Self.locate(path, bucket: bucket, resolve: resolve)
            }.value
            guard !Task.isCancelled else { return }
            await self?.finish(path, found: found, columnWidth: columnWidth,
                               backingScale: backingScale)
        }
    }

    private func finish(_ path: String, found: Located, columnWidth: CGFloat,
                        backingScale: CGFloat) async {
        defer { if !Task.isCancelled { work[path] = nil } }
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
                Self.decode(url, columnWidth: columnWidth, backingScale: backingScale)
            }.value
            guard !Task.isCancelled else { return }
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
    nonisolated private static func locate(_ path: String, bucket: Int,
                                           resolve: Resolve) -> Located {
        switch resolve(path) {
        case .file(let url):
            if url.pathExtension.lowercased() == "svg" { return .notShown(svgMessage) }
            let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate
            return .file(FigureThumbnailKey(path: url.path, modified: modified, bucket: bucket), url)
        case .notLocal, .unreadable:
            return .notShown(notFoundMessage)
        }
    }

    struct Decoded: @unchecked Sendable {   // CGImage is immutable
        let image: CGImage
        let natural: CGSize
    }

    /// A thumbnail at the size it is drawn at in `columnWidth` on a screen of
    /// `backingScale` (`FigureThumbnailLayout.decodePixelSize`): ImageIO's
    /// thumbnailer for a raster (never a full decode), page 1 for a PDF. The
    /// natural size comes from the header first, so the decode is no larger
    /// than the drawing. `natural` is the picture's own size in points (one
    /// pixel each, the way a browser shows an image; a PDF page's own size).
    nonisolated static func decode(_ url: URL, columnWidth: CGFloat,
                                   backingScale: CGFloat) -> Decoded? {
        if url.pathExtension.lowercased() == "pdf" {
            return decodePDF(url, columnWidth: columnWidth, backingScale: backingScale)
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetCount(source) > 0,
              let natural = orientedPixelSize(source) else { return nil }
        let maxPixelSize = FigureThumbnailLayout.decodePixelSize(
            natural: natural, columnWidth: columnWidth, backingScale: backingScale)
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { return nil }
        return Decoded(image: image, natural: natural)
    }

    /// The picture's pixel size from its header (no decode), as displayed:
    /// EXIF orientations 5–8 turn it a quarter, so width and height swap.
    nonisolated private static func orientedPixelSize(_ source: CGImageSource) -> CGSize? {
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
              let h = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue,
              w > 0, h > 0 else { return nil }
        let orientation = (props[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        return (5...8).contains(orientation) ? CGSize(width: h, height: w) : CGSize(width: w, height: h)
    }

    nonisolated private static func decodePDF(_ url: URL, columnWidth: CGFloat,
                                              backingScale: CGFloat) -> Decoded? {
        guard let document = CGPDFDocument(url as CFURL), !document.isEncrypted,
              let page = document.page(at: 1) else { return nil }
        let box = page.getBoxRect(.cropBox)
        guard box.width > 0, box.height > 0 else { return nil }
        let maxPixelSize = FigureThumbnailLayout.decodePixelSize(
            natural: box.size, columnWidth: columnWidth, backingScale: backingScale)
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
/// line's thumbnail, or its table card (`FigureCardDrawing`, report plan 7a
/// Task 6), into the gap its paragraph spacing left. It reads only
/// cached data per draw: the coordinator's figure marks and the store's
/// answers (tripwire 4).
final class FigureThumbnailOverlay: NSView {
    weak var coordinator: EditorCoordinator?
    weak var associatedTextView: NSTextView?
    /// How many figure lines the last draw found in view (the mounted test's
    /// reading; nothing is drawn for none).
    private(set) var lastVisibleFigureCount = 0

    /// What the last draw put under each figure line in view, in document
    /// order (the mounted tests' reading).
    enum Drawn: Equatable {
        case card(FigureCardModel.Kind)
        case thumbnail
        case box(String)
    }
    private(set) var lastDrawn: [Drawn] = []

    /// Each card's plan at the origin, kept while its model, the column and
    /// the font are unchanged, so a scroll measures no text (tripwire 4).
    private var cardPlans: [String: CardPlanEntry] = [:]
    private struct CardPlanEntry {
        let model: FigureCardModel
        let columnWidth: CGFloat
        let fontSize: CGFloat
        let plan: FigureCardDrawing.Plan
    }
    private static let cardPlanLimit = 64

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
    /// Skipped when there is no figure now and none was in view at the last
    /// draw: a figure-free manuscript never repaints its overlay.
    @objc private func repaint(_ note: Notification) {
        guard lastVisibleFigureCount > 0 || coordinator?.hasFigureLines == true else { return }
        repaintRequests += 1
        needsDisplay = true
    }
    /// How many observed changes asked for a repaint (the M5 test's reading).
    private(set) var repaintRequests = 0

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        lastVisibleFigureCount = 0
        lastDrawn = []
        guard let textView = associatedTextView,
              let layoutManager = textView.layoutManager,
              let container = textView.textContainer,
              let storage = textView.textStorage,
              let coordinator,
              let store = coordinator.figureThumbnailStore else { return }
        let marks = coordinator.figureThumbnailMarks
        guard !marks.isEmpty else { return }

        // The thumbnail or card hangs BELOW its line, so a line just above
        // the view can still show one: look the tallest room higher than the
        // view's top.
        let typography = coordinator.typography
        let reach = FigureCardMetrics.maxRoom(typography: typography)
        let origin = textView.textContainerOrigin
        var probe = textView.visibleRect.offsetBy(dx: -origin.x, dy: -origin.y)
        probe.origin.y -= reach
        probe.size.height += reach
        let glyphs = layoutManager.glyphRange(forBoundingRect: probe, in: container)
        let chars = layoutManager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        let visible = FigureThumbnailLayout.marks(marks, intersecting: chars)
        lastVisibleFigureCount = visible.count
        guard !visible.isEmpty else { return }

        let padding = container.lineFragmentPadding
        let columnX = origin.x + padding
        let columnWidth = max(0, container.size.width - 2 * padding)
        let backingScale = window?.backingScaleFactor ?? 2
        let cardFont = FigureCardMetrics.font(for: typography)
        let rowHeight = FigureCardMetrics.rowHeight(for: typography)

        for mark in visible {
            guard mark.lineRange.length > 0, NSMaxRange(mark.lineRange) <= storage.length else { continue }
            let lastGlyph = layoutManager.glyphIndexForCharacter(at: NSMaxRange(mark.lineRange) - 1)
            let used = layoutManager.lineFragmentUsedRect(forGlyphAt: lastGlyph, effectiveRange: nil)
            let lineBottom = used.maxY + origin.y
            // The paragraph's alpha, so focus dimming dims the picture too.
            let alpha = (storage.attribute(.foregroundColor, at: mark.lineRange.location,
                                           effectiveRange: nil) as? NSColor)?.alphaComponent ?? 1

            if let model = coordinator.figureCardModel?(mark.path),
               let plan = cardPlan(for: mark.path, model: model, columnWidth: columnWidth,
                                   font: cardFont, rowHeight: rowHeight) {
                lastDrawn.append(.card(model.kind))
                // The room the layout holds now: the fragment's paragraph
                // spacing, or the text view's own height for a trailing
                // figure. A card that grew mid-burst is clipped to its old
                // room until its line re-lays out at the settle.
                let room: CGFloat = NSMaxRange(mark.lineRange) == storage.length
                    ? bounds.maxY - lineBottom
                    : layoutManager.lineFragmentRect(forGlyphAt: lastGlyph, effectiveRange: nil).maxY
                        + origin.y - lineBottom
                let frame = plan.card.offsetBy(dx: columnX, dy: lineBottom)
                if frame.intersects(dirtyRect) {
                    drawCard(plan, at: CGPoint(x: columnX, y: lineBottom),
                             clip: CGRect(x: frame.minX - 1, y: lineBottom,
                                          width: frame.width + 2, height: max(0, room)),
                             font: cardFont, alpha: alpha)
                }
                continue
            }
            guard let thumbnail = store.thumbnail(for: mark.path, columnWidth: columnWidth,
                                                  backingScale: backingScale) else { continue }
            switch thumbnail {
            case .image(let image, let natural):
                lastDrawn.append(.thumbnail)
                let frame = FigureThumbnailLayout.frame(
                    for: .image(natural: natural), lineBottom: lineBottom,
                    columnX: columnX, columnWidth: columnWidth)
                if frame.intersects(dirtyRect) { draw(image, in: frame, alpha: alpha) }
            case .unshowable(let message):
                lastDrawn.append(.box(message))
                let frame = FigureThumbnailLayout.frame(
                    for: .placeholder, lineBottom: lineBottom,
                    columnX: columnX, columnWidth: columnWidth)
                if frame.intersects(dirtyRect) { drawBox(message, in: frame, alpha: alpha) }
            }
        }
    }

    /// The card plan for the line written `path`, at the origin; nil for an
    /// image (the thumbnail draws it). Measured once per (model, column, font).
    private func cardPlan(for path: String, model: FigureCardModel, columnWidth: CGFloat,
                          font: NSFont, rowHeight: CGFloat) -> FigureCardDrawing.Plan? {
        guard model.kind != .image else { return nil }
        if let entry = cardPlans[path], entry.model == model, entry.columnWidth == columnWidth,
           entry.fontSize == font.pointSize {
            return entry.plan
        }
        let bold = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
        guard let plan = FigureCardDrawing.plan(
            for: model, lineBottom: 0, columnX: 0, columnWidth: columnWidth, rowHeight: rowHeight,
            measure: { text, isBold in
                (text as NSString).size(withAttributes: [.font: isBold ? bold : font]).width
            }) else { return nil }
        if cardPlans.count >= Self.cardPlanLimit { cardPlans.removeAll() }
        cardPlans[path] = CardPlanEntry(model: model, columnWidth: columnWidth,
                                        fontSize: font.pointSize, plan: plan)
        return plan
    }

    /// Paint `plan` shifted to `offset`, clipped to the room the layout holds.
    private func drawCard(_ plan: FigureCardDrawing.Plan, at offset: CGPoint, clip: CGRect,
                          font: NSFont, alpha: CGFloat) {
        NSGraphicsContext.saveGraphicsState()
        clip.clip()
        let shift = NSAffineTransform()
        shift.translateX(by: offset.x, yBy: offset.y)
        shift.concat()
        FigureCardDrawing.draw(plan, font: font, alpha: alpha)
        NSGraphicsContext.restoreGraphicsState()
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

    /// **The room under the figure line written `path`** (report plan 7a
    /// Task 4): what `ProseMode.reserveFigureThumbnailSpace` adds to the
    /// line's `paragraphSpacing` on BOTH paints, so window ≡ whole document.
    /// The card comes from `figureCardModel` (the window's `FigureCardCache`,
    /// memory only); a surface with no provider, or a figure the cache has
    /// not filled, gets the fixed placeholder (`FigureCardMetrics.room`).
    /// Asked once per figure line a paint covers, never on its own.
    func figureRoom(forLinePath path: String) -> CGFloat {
        FigureCardMetrics.room(for: figureCardModel?(path), typography: typography)
    }

    /// The room a figure on the document's LAST line needs below the text:
    /// TextKit 1 lays out no paragraph spacing after a final paragraph with no
    /// newline, so `MaughamTextView` adds this to its height instead
    /// (`heightHoldingATrailingFigure`). Zero otherwise. Text-derived.
    ///
    /// Asked of the text itself (`FigureThumbnailLayout.trailingFigurePath`),
    /// never of the marks: `setFrameSize` asks it mid-edit, before the
    /// retokenize (whole-branch review I1).
    ///
    /// The room is the line's own (`figureRoom(forLinePath:)`), so a table
    /// card on the last line keeps room for every row it grows to. It is
    /// memoised by path (`trailingFigureRoomMemo`): the keystroke path pays a
    /// string compare, and asks the cards again only when the path itself
    /// changes. A card version moves it only through `refreshFigureRooms`,
    /// so it moves at the same edge as every other figure line — never
    /// mid-burst.
    var figureTrailingRoom: CGFloat {
        guard showsFigureThumbnails, let textView,
              let path = FigureThumbnailLayout.trailingFigurePath(textView.string as NSString)
        else { return 0 }
        if let memo = trailingFigureRoomMemo, memo.path == path { return memo.room }
        trailingFigureRoomLookupCount += 1
        let room = figureRoom(forLinePath: path)
        trailingFigureRoomMemo = (path, room)
        return room
    }

    /// **The figure cards changed: re-lay out the lines whose room moved**
    /// (report plan 7a Task 5). Asks every figure line its room again
    /// (`figureThumbnailMarks`, the cache's own line resolution through
    /// `figureCardModel`) and restyles only the lines whose room differs from
    /// the one painted — one `addAttribute` per such line, never a
    /// `setAttributes`, so the caret and the scroll stay where they are.
    /// A card whose content changed but whose height did not re-lays out
    /// nothing; the overlay repaints for it. Then the trailing figure's room
    /// is re-held, since it is asked of the same cards.
    ///
    /// Callers: `setFigureCardVersion` outside a burst, the settle paint
    /// after one. Never on the keystroke.
    func refreshFigureRooms() {
        guard !isDetached, showsFigureThumbnails, !tokensDescribeAnEarlierText,
              let prose = mode as? ProseMode,
              let textView, let storage = textView.textStorage else { return }
        figureRoomsWaitForTheSettle = false
        trailingFigureRoomMemo = nil   // the trailing card is asked again, here only
        let touched = prose.refreshFigureRooms(
            in: storage, theme: theme, typography: typography,
            lines: figureThumbnailMarks, figureRoom: figureRoom(forLinePath:))
        figureRoomRefreshCount += touched.count
        holdTrailingFigureRoom(in: textView)
        figureThumbnailOverlay?.needsDisplay = true
    }

    /// Size the text view for the trailing figure's room: a room that shrank
    /// (gone, or a trailing card that lost rows) re-fits first, since the
    /// hold only ever grows the frame; any room is then held.
    private func holdTrailingFigureRoom(in textView: NSTextView) {
        let room = figureTrailingRoom
        let shrank = room < lastFigureTrailingRoom
        lastFigureTrailingRoom = room
        if shrank { textView.sizeToFit() }
        if room > 0, let maugham = textView as? MaughamTextView {
            maugham.holdTrailingFigureRoom()
        }
    }

    /// After a retokenize: hold the room for a trailing figure, and repaint
    /// the overlay when there are figures or were some in view.
    ///
    /// While there is room, the frame is re-asserted after EVERY retokenize,
    /// not only when the room flips: `sizeToFit` never calls `setFrameSize`
    /// when the layout's size already equals the frame, and AppKit's own
    /// mid-edit resize can land before this (whole-branch review I1). The
    /// re-assert grows the frame only when it falls short, so it costs one
    /// comparison on a keystroke that changes nothing. Losing the room shrinks
    /// through `sizeToFit`, as before.
    func figureThumbnailTokensDidChange() {
        guard showsFigureThumbnails, let textView else { return }
        holdTrailingFigureRoom(in: textView)
        if let overlay = figureThumbnailOverlay,
           overlay.lastVisibleFigureCount > 0 || hasFigureLines {
            overlay.needsDisplay = true
        }
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
