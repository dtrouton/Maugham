import XCTest
import AppKit
import MaughamCore
@testable import Maugham

/// The thumbnail beneath a figure line (plan 3a Task 7): a decoration drawn by
/// `FigureThumbnailOverlay`, never an attachment. The space comes from the
/// figure line's `paragraphSpacing` (`ProseMode.reservesFigureThumbnails`);
/// the picture is decoded off the main thread and cached by (resolved path,
/// modification date).
///
/// No pixel snapshots and no press-then-wait: the cache, the layout maths, the
/// spacing attribute and the store are asserted as values, and the one mounted
/// test reads what the overlay found in view.
@MainActor
final class FigureThumbnailTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        FontWarmup.ensure()   // the spacing and mounted tests style through ProseMode
    }

    // MARK: - The cache

    private func key(_ path: String, _ seconds: TimeInterval) -> FigureThumbnailKey {
        FigureThumbnailKey(path: path, modified: Date(timeIntervalSince1970: seconds))
    }

    func test_cache_isKeyedByPathAndModificationDate() {
        let cache = FigureThumbnailCache<Int>(capacity: 4)
        cache.insert(1, for: key("/r/a.png", 100))
        XCTAssertEqual(cache.value(for: key("/r/a.png", 100)), 1)
        XCTAssertNil(cache.value(for: key("/r/a.png", 200)),
                     "a re-saved image (new modification date) is a different entry")
        XCTAssertNil(cache.value(for: key("/r/b.png", 100)), "another path is another entry")
    }

    func test_cache_isBoundedAndEvictsTheLeastRecentlyUsed() {
        let cache = FigureThumbnailCache<Int>(capacity: 2)
        cache.insert(1, for: key("a", 0))
        cache.insert(2, for: key("b", 0))
        _ = cache.value(for: key("a", 0))        // a is now the most recent
        cache.insert(3, for: key("c", 0))        // evicts b, the least recent
        XCTAssertEqual(cache.count, 2)
        XCTAssertEqual(cache.value(for: key("a", 0)), 1)
        XCTAssertNil(cache.value(for: key("b", 0)))
        XCTAssertEqual(cache.value(for: key("c", 0)), 3)
    }

    func test_cache_reinsertingAKeyReplacesItWithoutGrowing() {
        let cache = FigureThumbnailCache<Int>(capacity: 2)
        cache.insert(1, for: key("a", 0))
        cache.insert(9, for: key("a", 0))
        XCTAssertEqual(cache.count, 1)
        XCTAssertEqual(cache.value(for: key("a", 0)), 9)
    }

    func test_theEditorsCacheIsSmall() {
        XCTAssertLessThanOrEqual(FigureThumbnailStore.cacheCapacity, 32)
        XCTAssertGreaterThan(FigureThumbnailStore.cacheCapacity, 0)
    }

    // MARK: - Layout maths

    func test_fittedSize_fitsTheColumnAndTheHeightCapWithoutUpscaling() {
        let fit = { FigureThumbnailLayout.fittedSize(natural: $0, columnWidth: 600) }
        XCTAssertEqual(fit(CGSize(width: 2000, height: 500)), CGSize(width: 480, height: 120),
                       "a wide picture is held to 120 pt tall")
        XCTAssertEqual(fit(CGSize(width: 300, height: 900)), CGSize(width: 40, height: 120),
                       "a tall picture is held to 120 pt tall")
        XCTAssertEqual(fit(CGSize(width: 3000, height: 300)), CGSize(width: 600, height: 60),
                       "a panorama is held to the column width")
        XCTAssertEqual(fit(CGSize(width: 100, height: 50)), CGSize(width: 100, height: 50),
                       "a small picture is never blown up")
        XCTAssertEqual(fit(CGSize(width: 0, height: 0)), .zero)
    }

    func test_frames_sitBelowTheLineAtTheColumnsLeftEdge() {
        let image = FigureThumbnailLayout.frame(
            for: .image(natural: CGSize(width: 2000, height: 500)),
            lineBottom: 300, columnX: 40, columnWidth: 600)
        XCTAssertEqual(image, CGRect(x: 40, y: 300 + FigureThumbnailLayout.gap,
                                     width: 480, height: 120))

        let box = FigureThumbnailLayout.frame(
            for: .placeholder, lineBottom: 300, columnX: 40, columnWidth: 600)
        XCTAssertEqual(box.origin, CGPoint(x: 40, y: 300 + FigureThumbnailLayout.gap))
        XCTAssertEqual(box.height, FigureThumbnailLayout.placeholderHeight)
        XCTAssertLessThan(box.height, FigureThumbnailLayout.maxHeight,
                          "the not-found box is smaller than a thumbnail")
        XCTAssertLessThanOrEqual(box.width, 600)

        let narrow = FigureThumbnailLayout.frame(
            for: .placeholder, lineBottom: 0, columnX: 0, columnWidth: 90)
        XCTAssertEqual(narrow.width, 90, "the box never overruns a narrow column")
    }

    func test_reservedHeight_holdsTheTallestThumbnailAndItsGaps() {
        XCTAssertEqual(FigureThumbnailLayout.maxHeight, 120)
        XCTAssertEqual(FigureThumbnailLayout.reservedHeight,
                       FigureThumbnailLayout.maxHeight + 2 * FigureThumbnailLayout.gap)
    }

    func test_maxPixelSize_coversTheColumnAtTheBackingScale() {
        XCTAssertEqual(FigureThumbnailLayout.maxPixelSize(columnWidth: 600, backingScale: 2), 1200)
        XCTAssertEqual(FigureThumbnailLayout.maxPixelSize(columnWidth: 80, backingScale: 2), 240,
                       "never less than the height cap")
        XCTAssertEqual(FigureThumbnailLayout.maxPixelSize(columnWidth: 600, backingScale: 1), 600)
    }

    // MARK: - Which lines are figures

    private let twoFigures = """
    Opening paragraph with a [real link](https://example.com).

    ![Revenue by year](../research/rev.png){#fig:revenue}

    Middle.

    ![](../research/empty-caption.pdf)
    """

    func test_marks_findEachFigureLineAndItsPath() {
        let tokens = ProseMode().tokenize(twoFigures)
        let marks = FigureThumbnailLayout.marks(in: tokens, text: twoFigures as NSString)
        XCTAssertEqual(marks.map(\.path), ["../research/rev.png", "../research/empty-caption.pdf"])
        let ns = twoFigures as NSString
        XCTAssertEqual(ns.substring(with: marks[0].lineRange),
                       "![Revenue by year](../research/rev.png){#fig:revenue}")
        XCTAssertEqual(ns.substring(with: marks[1].lineRange), "![](../research/empty-caption.pdf)")
    }

    func test_marks_inAVisibleRange_areFoundByBinarySearch() {
        let text = (0..<200).map { i in
            i % 10 == 0 ? "![F\(i)](../research/f\(i).png)" : "Paragraph \(i)."
        }.joined(separator: "\n\n") as NSString
        let marks = FigureThumbnailLayout.marks(in: ProseMode().tokenize(text as String), text: text)
        XCTAssertEqual(marks.count, 20)
        for window in [NSRange(location: 0, length: 0),
                       NSRange(location: 0, length: text.length / 7),
                       NSRange(location: text.length / 2, length: text.length / 9),
                       NSRange(location: text.length - 30, length: 30),
                       NSRange(location: 0, length: text.length)] {
            let found = FigureThumbnailLayout.marks(marks, intersecting: window).map(\.path)
            let expected = marks.filter {
                NSIntersectionRange($0.lineRange, window).length > 0
            }.map(\.path)
            XCTAssertEqual(found, expected, "window \(window)")
        }
    }

    // MARK: - The reserved space

    private func styled(_ text: String, mode: ProseMode) -> NSTextStorage {
        let storage = NSTextStorage(string: text)
        mode.applyTypography(in: storage, theme: .light, typography: .defaults,
                             tokens: mode.tokenize(text), wikiLinkResolver: nil)
        return storage
    }

    private func spacing(_ s: NSTextStorage, at needle: String) -> CGFloat {
        let at = (s.string as NSString).range(of: needle).location
        return (s.attribute(.paragraphStyle, at: at, effectiveRange: nil) as? NSParagraphStyle)?
            .paragraphSpacing ?? -1
    }

    func test_aManuscriptReservesTheThumbnailsSpaceUnderEachFigureLine() {
        let s = styled(twoFigures, mode: ProseMode(reservesFigureThumbnails: true))
        let body = spacing(s, at: "Middle")
        XCTAssertEqual(spacing(s, at: "![Revenue"), body + FigureThumbnailLayout.reservedHeight)
        XCTAssertEqual(spacing(s, at: "{#fig:revenue}"), body + FigureThumbnailLayout.reservedHeight,
                       "the whole line carries it, not just the `![`")
        XCTAssertEqual(spacing(s, at: "![](../research/empty"), body + FigureThumbnailLayout.reservedHeight)
        XCTAssertEqual(spacing(s, at: "Opening"), body, "a prose line keeps its own spacing")
    }

    /// A research note and a statement share `ProseMode` but show no thumbnail,
    /// so they reserve no space.
    func test_otherProseSurfacesReserveNothing() {
        let s = styled(twoFigures, mode: ProseMode())
        XCTAssertEqual(spacing(s, at: "![Revenue"), spacing(s, at: "Middle"))
    }

    // MARK: - The store

    private func writePNG(to url: URL, width: Int, height: Int) throws {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        try rep.representation(using: .png, properties: [:])!.write(to: url)
    }

    private func writePDF(to url: URL, width: CGFloat, height: CGFloat) {
        var box = CGRect(x: 0, y: 0, width: width, height: height)
        let ctx = CGContext(url as CFURL, mediaBox: &box, nil)!
        ctx.beginPDFPage(nil)
        ctx.setFillColor(NSColor.red.cgColor)
        ctx.fill(box.insetBy(dx: 10, dy: 10))
        ctx.endPDFPage()
        ctx.closePDF()
    }

    private func store(resolving: [String: URL]) -> FigureThumbnailStore {
        FigureThumbnailStore { path in
            resolving[path].map(FigureImageResolver.Outcome.file) ?? .notLocal
        }
    }

    func test_store_decodesARasterThumbnailAtItsNaturalSize() async throws {
        let png = TestTemp.root.appendingPathComponent("a.png")
        try writePNG(to: png, width: 400, height: 100)
        let store = store(resolving: ["../research/a.png": png])
        XCTAssertNil(store.thumbnail(for: "../research/a.png", maxPixelSize: 200),
                     "nothing is known before the first decode lands")
        await store.pendingWork(for: "../research/a.png")?.value
        guard case .image(let image, let natural)? = store.thumbnail(for: "../research/a.png",
                                                                      maxPixelSize: 200) else {
            return XCTFail("expected a thumbnail")
        }
        XCTAssertEqual(natural, CGSize(width: 400, height: 100))
        XCTAssertLessThanOrEqual(max(image.width, image.height), 200,
                                 "decoded as a thumbnail, never in full")
    }

    func test_store_rendersAPDFsFirstPage() async throws {
        let pdf = TestTemp.root.appendingPathComponent("p.pdf")
        writePDF(to: pdf, width: 300, height: 150)
        let store = store(resolving: ["p.pdf": pdf])
        _ = store.thumbnail(for: "p.pdf", maxPixelSize: 120)
        await store.pendingWork(for: "p.pdf")?.value
        guard case .image(let image, let natural)? = store.thumbnail(for: "p.pdf", maxPixelSize: 120)
        else { return XCTFail("expected page 1") }
        XCTAssertEqual(natural, CGSize(width: 300, height: 150))
        XCTAssertEqual(image.width, 120)
    }

    func test_store_anUnresolvableOrUndecodableImageIsNotFound() async throws {
        let junk = TestTemp.root.appendingPathComponent("junk.png")
        try Data("not a picture".utf8).write(to: junk)
        let store = store(resolving: ["junk.png": junk])
        for path in ["junk.png", "../elsewhere/x.png"] {
            _ = store.thumbnail(for: path, maxPixelSize: 100)
            await store.pendingWork(for: path)?.value
            XCTAssertEqual(store.thumbnail(for: path, maxPixelSize: 100)?.message,
                           FigureThumbnailStore.notFoundMessage, path)
        }
    }

    func test_store_anSVGIsNotShown() async throws {
        let svg = TestTemp.root.appendingPathComponent("d.svg")
        try Data("<svg xmlns=\"http://www.w3.org/2000/svg\"/>".utf8).write(to: svg)
        let store = store(resolving: ["d.svg": svg])
        _ = store.thumbnail(for: "d.svg", maxPixelSize: 100)
        await store.pendingWork(for: "d.svg")?.value
        XCTAssertEqual(store.thumbnail(for: "d.svg", maxPixelSize: 100)?.message,
                       FigureThumbnailStore.svgMessage)
    }

    /// The same file under two written spellings decodes once: the cache is
    /// keyed by the RESOLVED path and its modification date.
    func test_store_decodesOneResolvedFileOnce() async throws {
        let png = TestTemp.root.appendingPathComponent("once.png")
        try writePNG(to: png, width: 10, height: 10)
        let store = store(resolving: ["a/once.png": png, "a/./once.png": png])
        for path in ["a/once.png", "a/./once.png"] {
            _ = store.thumbnail(for: path, maxPixelSize: 50)
            await store.pendingWork(for: path)?.value
        }
        XCTAssertEqual(store.decodeCount, 1)
    }

    func test_store_tellsItsOverlayWhenADecodeLands() async throws {
        let png = TestTemp.root.appendingPathComponent("tell.png")
        try writePNG(to: png, width: 10, height: 10)
        let store = store(resolving: ["tell.png": png])
        var updates = 0
        store.onUpdate = { updates += 1 }
        _ = store.thumbnail(for: "tell.png", maxPixelSize: 50)
        await store.pendingWork(for: "tell.png")?.value
        XCTAssertEqual(updates, 1)
    }

    // MARK: - Mounted

    private let farFigure: String = {
        let filler = (0..<400).map { "Paragraph \($0) of plain prose, long enough to wrap a little." }
        return filler.joined(separator: "\n\n") + "\n\n![Far away](../research/far.png)"
    }()

    private func mounted(_ text: String, resolver: Bool = true) -> EditorIntegrationHarness {
        let harness = EditorIntegrationHarness(
            mode: ProseMode(reservesFigureThumbnails: true), initialText: text, cursorLocation: 0)
        if resolver {
            harness.coordinator.figureImageResolver = { _ in .notLocal }
        }
        harness.coordinator.attach(to: harness.textView)   // the production install point
        harness.textView.scrollToBeginningOfDocument(nil)
        return harness
    }

    func test_mounted_theOverlayInstallsOnAManuscriptAndFindsNoFigureOutOfView() throws {
        let harness = mounted(farFigure)
        let overlay = try XCTUnwrap(harness.coordinator.figureThumbnailOverlay,
                                    "a manuscript with a resolver gets the overlay")
        XCTAssertTrue(overlay.superview === harness.textView)
        XCTAssertNil(overlay.hitTest(NSPoint(x: 10, y: 10)), "it never takes a click")
        overlay.display()
        XCTAssertEqual(overlay.lastVisibleFigureCount, 0,
                       "the only figure is far below the visible range")
    }

    /// The control: the same overlay with a figure in view finds it.
    func test_mounted_aFigureInViewIsFound() throws {
        let harness = mounted("![Near](../research/near.png)\n\nAfter.")
        let overlay = try XCTUnwrap(harness.coordinator.figureThumbnailOverlay)
        overlay.display()
        XCTAssertEqual(overlay.lastVisibleFigureCount, 1)
    }

    /// A surface with no resolver (a research note, a statement) gets none.
    func test_mounted_noResolverNoOverlay() {
        let harness = mounted("![Near](../research/near.png)", resolver: false)
        XCTAssertNil(harness.coordinator.figureThumbnailOverlay)
    }
}
