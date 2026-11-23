import XCTest
import AppKit
import SwiftUI
import MaughamCore
@testable import Maugham

/// **The tree's top-level disclosures share one column, and the section
/// titles another** (owner's hand check, 2026-11-21: *"the tree seems to
/// indent research and then palette - I'm not sure why?"*).
///
/// Research and Figures are `Section` headers; the Palette is a selectable
/// row. A sidebar `List` lays a header's content out from x=14 and a
/// top-level row's cell from x=25, so one drawn chevron landed at two x's and
/// Palette read as nested under Research. Now the Palette is a
/// `DisclosureGroup` (its triangle is the outline's own, beside every
/// chapter's) and the headers centre theirs on that gutter
/// (`TreeSectionColumn`); this suite is that type's measurement.
///
/// **Measured as ink**, the way `BinderTreeIndentationTests` measures rows: a
/// SwiftUI row's text has no frame to read, so the window is rendered and
/// each row's leftmost drawn column is asked for. The chevron buttons'
/// frames are read too (a header's is its focus-ring view, as
/// `SectionChevronTests` finds it; a row's triangle is
/// `NSOutlineView.frameOfOutlineCell(atRow:)`).
///
/// **Not measured: a selected Palette row.** `cacheDisplay` draws a selected
/// row's vibrant fill as solid black, so the title's white-on-accent turn
/// (`TreeSectionInk`) is a hand check. A click on each chevron is
/// `SectionChevronTests`' and `BinderTreeSectionsTests`' to pin.
@MainActor
final class TreeTopLevelAlignmentTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        FontWarmup.ensure()
    }

    private var temp: TempDirectory!
    private var windows: [NSWindow] = []
    private var documentStores: [DocumentStore] = []

    /// How far a section's rows must sit right of its title to read as
    /// beneath it — `BinderTreeIndentationTests.minimumStep`'s reasoning.
    private let minimumStep: CGFloat = 6

    override func setUp() async throws { temp = TempDirectory() }

    override func tearDown() async throws {
        for window in windows { window.contentView = NSView(frame: .zero) }
        pump(0.05)
        windows.removeAll()
        for ds in documentStores { await ds.close() }
        documentStores.removeAll()
        temp.cleanup()
        temp = nil
    }

    // MARK: - One chevron column

    /// **Research's chevron, the Palette's and a chapter's triangle are one
    /// column** — open and closed, since a closed section is where the
    /// writer compares them.
    func test_theSectionChevronsShareTheChaptersDisclosureColumn() async throws {
        let tree = try await mountNovel()

        for open in [true, false] {
            tree.state.researchSectionExpanded = open
            tree.state.paletteSectionExpanded = open
            pump(0.3)
            let shot = try Shot(tree.window)
            let chapter = try shot.row(tree.chapterRow)
            let research = try shot.sectionRow(.research)
            let palette = try shot.sectionRow(.palette)
            let state = open ? "open" : "closed"

            XCTAssertEqual(palette.chevron.minX, chapter.triangle.minX, accuracy: 1,
                           "\(state): the Palette's triangle starts at "
                           + "\(palette.chevron.minX), a chapter's at "
                           + "\(chapter.triangle.minX) — the reported indent")
            XCTAssertEqual(research.chevronInk.mid, palette.chevronInk.mid, accuracy: 1,
                           "\(state): Research's chevron is drawn around "
                           + "\(research.chevronInk.mid), the Palette's around "
                           + "\(palette.chevronInk.mid)")
            XCTAssertEqual(research.chevronInk.mid, chapter.triangle.midX, accuracy: 1,
                           "\(state): Research's chevron is drawn around "
                           + "\(research.chevronInk.mid), off the gutter's centre "
                           + "\(chapter.triangle.midX)")
            if !open {
                // Closed, the glyphs are one shape, so their ink can be
                // compared edge for edge.
                XCTAssertEqual(research.chevronInk.lowerBound, chapter.firstInk, accuracy: 1,
                               "closed: Research's chevron ink starts at "
                               + "\(research.chevronInk.lowerBound), a chapter's at "
                               + "\(chapter.firstInk)")
                XCTAssertEqual(research.chevronInk.upperBound - research.chevronInk.lowerBound,
                               palette.chevronInk.upperBound - palette.chevronInk.lowerBound,
                               accuracy: 1, "closed: the two chevrons are different sizes")
            }
        }
    }

    /// The same column in the Collection's tree — a second host, with its own
    /// inset on its pieces, and `ProjectRowLabel.childIndent`'s comment warns
    /// that an outdented header lands differently per pane.
    func test_theColumnHoldsInTheCollectionsTreeToo() async throws {
        let store = try await collection()
        let piece = try await store.addLoosePiece(title: "Alpha", format: .markdown)
        _ = try await store.addPieceResearchNote(pieceId: piece.id, title: "Alpha's Note")
        _ = try await store.addResearchTextNote(parentId: nil, title: "Shared")
        _ = try await store.addPaletteCard(title: "A place", kind: .location)
        let state = BinderTreeSectionsState()
        let window = try await mount(AnyView(
            AlignmentCollectionProbe(store: store, treeState: state)))
        let outline = try XCTUnwrap(Shot.outline(in: window))
        let pieceRow = try XCTUnwrap(
            (0..<outline.numberOfRows).first { outline.frameOfOutlineCell(atRow: $0).width > 0 },
            "no top-level row carries a triangle")

        let shot = try Shot(window)
        let triangle = try shot.row(pieceRow).triangle
        let research = try shot.sectionRow(.research)
        let palette = try shot.sectionRow(.palette)
        XCTAssertEqual(research.chevronInk.mid, triangle.midX, accuracy: 1,
                       "Research's chevron at \(research.chevronInk.mid), a piece's "
                       + "triangle centred on \(triangle.midX)")
        XCTAssertEqual(palette.chevron.minX, triangle.minX, accuracy: 1,
                       "Palette \(palette.chevron.minX), a piece's triangle \(triangle.minX)")
        XCTAssertEqual(palette.titleInk, research.titleInk, accuracy: 1,
                       "titles at \(research.titleInk) and \(palette.titleInk)")
    }

    // MARK: - One title column

    /// **Research, Palette and Editions start their titles at one x** —
    /// Editions has no chevron, so its text starts in the titles' column.
    func test_theSectionTitlesStartAtOneX() async throws {
        let tree = try await mountNovel()
        let shot = try Shot(tree.window)
        let research = try shot.sectionRow(.research)
        let palette = try shot.sectionRow(.palette)
        let editions = try shot.editionsHeader()

        XCTAssertEqual(palette.titleInk, research.titleInk, accuracy: 1,
                       "Research's title starts at \(research.titleInk), the "
                       + "Palette's at \(palette.titleInk)")
        XCTAssertEqual(editions, research.titleInk, accuracy: 1,
                       "Editions starts at \(editions), the titles at "
                       + "\(research.titleInk)")
        XCTAssertGreaterThan(research.titleInk, research.chevron.maxX - 1,
                             "the title must clear its chevron")

        // And the `+` glyphs end at one x: Research's menu, the Palette's,
        // and the Editions header's plain button (shell p4 Task 7 fix round).
        let menus = Shot.descendants(of: shot.content)
            .filter { String(describing: type(of: $0)).contains("SwiftUIPopupButton") }
            .map { $0.convert($0.bounds, to: shot.content) }
        XCTAssertEqual(menus.count, 2, "premise: Research's `+` and the Palette's are menus")
        if menus.count == 2 {
            XCTAssertEqual(menus[0].maxX, menus[1].maxX, accuracy: 1,
                           "the `+` menus end at \(menus.map(\.maxX))")
        }
        let headers = shot.headerRows()
        let researchHeader = try XCTUnwrap(headers.first, "premise: Research's header is drawn")
        let editionsHeader = try XCTUnwrap(headers.last, "premise: the Editions header is drawn")
        func lastInk(_ header: NSView) throws -> CGFloat {
            let frame = header.convert(header.bounds, to: shot.content)
            return try XCTUnwrap(shot.inkRuns(in: frame).last, "a header drew nothing").upperBound
        }
        XCTAssertEqual(try lastInk(editionsHeader), try lastInk(researchHeader), accuracy: 1,
                       "the Editions `+` glyph ends where Research's does")
    }

    /// **Each section's rows sit beneath its title, at one depth**: a
    /// Research note, a Palette card and an edition, all right of the titles
    /// and level with each other.
    func test_eachSectionsRowsSitBeneathItsTitle() async throws {
        let tree = try await mountNovel()
        let shot = try Shot(tree.window)
        let title = try shot.sectionRow(.research).titleInk
        let note = try shot.row(drawing: .research(tree.note)).firstInk
        let card = try shot.row(drawing: .research(tree.card)).firstInk
        let edition = try shot.row(drawing: .edition(language: "en")).firstInk

        for (name, x) in [("note", note), ("card", card), ("edition", edition)] {
            XCTAssertGreaterThan(x, title + minimumStep,
                                 "the \(name) starts at \(x), its title at \(title)")
        }
        // Different glyphs carry different side bearings (2pt, measured).
        XCTAssertEqual(note, card, accuracy: 3, "note \(note), card \(card)")
        XCTAssertEqual(edition, card, accuracy: 3, "edition \(edition), card \(card)")
    }

    // MARK: - One look

    /// **`treeSectionTitle()` is the sidebar header's own look** — the
    /// claim that lets the Palette ROW wear it and match Research. A plain
    /// header and a styled one, rendered, must draw the same pixels.
    func test_theSectionTitleStyleIsTheSidebarHeadersOwn() async throws {
        let window = try await mount(AnyView(HeaderStyleProbe()))
        let shot = try Shot(window)
        let headers = shot.headerRows()
        XCTAssertEqual(headers.count, 2, "premise: two drawn headers")
        guard headers.count == 2 else { return }
        let plain = shot.inkPattern(of: headers[0])
        let styled = shot.inkPattern(of: headers[1])
        XCTAssertFalse(plain.isEmpty, "the plain header drew nothing")
        XCTAssertEqual(plain.count, styled.count,
                       "the two titles are \(plain.count) and \(styled.count) px wide")
        let diff = zip(plain, styled).map { zip($0, $1).map { abs($0 - $1) }.reduce(0, +) }
            .reduce(0, +)
        XCTAssertLessThan(diff, 1, "the styled title's pixels differ by \(diff)")
    }

    // MARK: - Fixtures

    private struct NovelTree {
        let window: NSWindow
        let state: BinderTreeSectionsState
        let chapterRow: Int
        let note: String
        let card: String
    }

    /// A novel whose first chapter has a linked note (so it carries a
    /// triangle), a whole-book note in Research (a linked one is drawn only in
    /// its chapter's fold), a card and a source edition.
    private func mountNovel() async throws -> NovelTree {
        let url = try await ProjectFactory.createNovelProject(
            named: "Novel-\(UUID().uuidString.prefix(6))", in: temp.url)
        let store = try await furnish(try await ProjectStore.load(from: url))
        let chapter = try XCTUnwrap(store.manifest.structure.first)
        let note = try await store.addResearchTextNote(parentId: nil, title: "Tides")
        try await store.linkResearch(researchId: note.id, toDocumentId: chapter.id)
        let book = try await store.addResearchTextNote(parentId: nil, title: "Charts")
        let card = try await store.addPaletteCard(title: "A place", kind: .location)
        let state = BinderTreeSectionsState()
        let window = try await mount(AnyView(AlignmentBinderProbe(store: store, treeState: state)))
        // The editions load once per manifest change; the fixture sets them.
        state.editionRows = [.init(language: "en", title: "English", isSource: true)]
        pump(0.3)
        let outline = try XCTUnwrap(Shot.outline(in: window))
        let chapterRow = try XCTUnwrap(
            (0..<outline.numberOfRows).first { outline.frameOfOutlineCell(atRow: $0).width > 0 },
            "the linked chapter carries no triangle")
        return NovelTree(window: window, state: state, chapterRow: chapterRow,
                         note: book.id, card: card.id)
    }

    private func collection() async throws -> ProjectStore {
        let url = try await ProjectFactory.createCollectionProject(
            named: "Collection-\(UUID().uuidString.prefix(6))", in: temp.url)
        return try await furnish(try await ProjectStore.load(from: url))
    }

    private func furnish(_ store: ProjectStore) async throws -> ProjectStore {
        let ds = try await DocumentStore.open(url: store.url)
        store.documentStore = ds
        documentStores.append(ds)
        await store.wordCountPopulationTask?.value
        return store
    }

    private func mount(_ root: AnyView) async throws -> NSWindow {
        let window = TestWindow.mount(root, size: CGSize(width: 320, height: 700),
                                      as: SilentTestWindow.self)
        windows.append(window)
        await pumpUntil(deadline: 5) { Shot.outline(in: window) != nil }
        // The palette's cards load a turn after the list does.
        pump(0.4)
        return window
    }
}

// MARK: - Measuring

/// One render of the window, and what each row drew where — in the content
/// view's coordinates. Nothing is selected while it is taken: a selection's
/// capsule is ink this measurement is not about.
@MainActor
private struct Shot {
    let content: NSView
    let outline: NSOutlineView
    let rep: NSBitmapImageRep
    let scale: CGFloat

    init(_ window: NSWindow) throws {
        content = try XCTUnwrap(window.contentView)
        outline = try XCTUnwrap(Shot.outline(in: window))
        outline.deselectAll(nil)
        RunLoopPump.spin(0.2)
        rep = try XCTUnwrap(content.bitmapImageRepForCachingDisplay(in: content.bounds))
        content.cacheDisplay(in: content.bounds, to: rep)
        scale = CGFloat(rep.pixelsWide) / content.bounds.width
    }

    static func outline(in window: NSWindow) -> NSOutlineView? {
        guard let content = window.contentView else { return nil }
        return descendants(of: content).compactMap { $0 as? NSOutlineView }.first
    }

    static func descendants(of view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { descendants(of: $0) }
    }

    struct Row {
        let frame: CGRect
        let triangle: CGRect
        let firstInk: CGFloat
    }

    struct SectionRow {
        /// The chevron's frame: a header's button, or a row's triangle.
        let chevron: CGRect
        let chevronInk: ClosedRange<CGFloat>
        let titleInk: CGFloat
    }

    enum Section { case research, palette }

    func row(_ index: Int) throws -> Row {
        let view = try XCTUnwrap(outline.rowView(atRow: index, makeIfNecessary: true),
                                 "no row \(index)")
        let frame = view.convert(view.bounds, to: content)
        let triangle = outline.convert(outline.frameOfOutlineCell(atRow: index), to: content)
        let first = try XCTUnwrap(inkRuns(in: frame).first, "row \(index) drew nothing")
        return Row(frame: frame, triangle: triangle, firstInk: first.lowerBound)
    }

    /// The row whose label carries `subject`'s travel mark
    /// (`TreeTravelTargetView`) — a row's text cannot be read, its mark can.
    func row(drawing subject: BinderSubject) throws -> Row {
        try row(rowIndex(drawing: subject))
    }

    func rowIndex(drawing subject: BinderSubject) throws -> Int {
        try XCTUnwrap(
            (0..<outline.numberOfRows).first { index in
                guard let view = outline.view(atColumn: 0, row: index, makeIfNecessary: true)
                else { return false }
                return Shot.descendants(of: view).contains {
                    ($0 as? TreeTravelTargetView)?.subject == subject
                }
            }, "no row draws \(subject)")
    }

    /// Research is the drawn header carrying a `+` menu, its chevron the
    /// header's one button; the Palette is the row whose title carries the
    /// `.palette` mark, its chevron that row's outline triangle.
    func sectionRow(_ section: Section) throws -> SectionRow {
        let chevron: CGRect
        let band: CGRect
        switch section {
        case .research:
            let header = try XCTUnwrap(headerRows().first { header in
                Shot.descendants(of: header).contains {
                    String(describing: type(of: $0)).contains("SwiftUIPopupButton")
                }
            }, "no drawn header carries a `+` menu")
            chevron = try XCTUnwrap(
                Shot.descendants(of: header)
                    .filter { String(describing: type(of: $0)).contains("FocusRing") }
                    .map { $0.convert($0.bounds, to: content) }
                    .min { $0.minX < $1.minX }, "Research mounted no chevron")
            band = chevron
        case .palette:
            let index = try rowIndex(drawing: .palette)
            let cell = outline.frameOfOutlineCell(atRow: index)
            XCTAssertGreaterThan(cell.width, 0, "the Palette row carries no triangle")
            chevron = outline.convert(cell, to: content)
            band = try row(index).frame
        }
        let runs = inkRuns(in: CGRect(x: 0, y: band.minY, width: content.bounds.width,
                                      height: band.height))
        let chevronInk = try XCTUnwrap(runs.first, "\(section)'s chevron drew nothing")
        XCTAssertLessThan(chevronInk.lowerBound, chevron.maxX,
                          "\(section)'s first ink is not its chevron")
        let title = try XCTUnwrap(runs.first { $0.lowerBound >= chevron.maxX - 1 },
                                  "\(section)'s title drew nothing")
        return SectionRow(chevron: chevron, chevronInk: chevronInk,
                          titleInk: title.lowerBound)
    }

    /// Where the Editions header's text starts: the drawn header with no
    /// button in it.
    func editionsHeader() throws -> CGFloat {
        // The last drawn header: the Editions section is the tree's last.
        let header = try XCTUnwrap(headerRows().last, "no Editions header is drawn")
        let frame = header.convert(header.bounds, to: content)
        return try XCTUnwrap(inkRuns(in: frame).first, "Editions drew nothing").lowerBound
    }

    /// The headers the list DRAWS, top to bottom — a headerless `Section`
    /// mounts one zero points tall.
    func headerRows() -> [NSView] {
        Shot.descendants(of: content)
            .filter { String(describing: type(of: $0)).contains("ListTableHeaderView")
                && $0.frame.height > 1 }
            .sorted { $0.convert($0.bounds, to: content).minY
                < $1.convert($1.bounds, to: content).minY }
    }

    /// A header's pixels as columns of darkening against its background,
    /// from its first ink to its last — so two headers drawing the same word
    /// in the same style give the same pattern wherever they sit.
    func inkPattern(of header: NSView) -> [[CGFloat]] {
        let frame = header.convert(header.bounds, to: content)
        let (y0, y1) = pixelRows(frame)
        guard y1 > y0, let bg = rgb(rep.colorAt(x: 2, y: (y0 + y1) / 2)) else { return [] }
        var columns: [[CGFloat]] = []
        for x in Int(frame.minX * scale)..<Int(frame.maxX * scale) {
            let column = (y0..<y1).map { y in
                (rgb(rep.colorAt(x: x, y: y))?.redComponent).map { bg.redComponent - $0 } ?? 0
            }
            if columns.isEmpty, !column.contains(where: { abs($0) > 0.06 }) { continue }
            columns.append(column)
        }
        while let last = columns.last, !last.contains(where: { abs($0) > 0.06 }) {
            columns.removeLast()
        }
        return columns
    }

    /// Runs of drawn columns in a horizontal band, as x ranges in points. The
    /// background is sampled at the band's left edge, inside the row's
    /// indentation, which never carries content.
    func inkRuns(in band: CGRect) -> [ClosedRange<CGFloat>] {
        let (y0, y1) = pixelRows(band)
        guard y1 > y0, let bg = rgb(rep.colorAt(x: 2, y: (y0 + y1) / 2)) else { return [] }
        var runs: [ClosedRange<CGFloat>] = []
        var start: Int?
        for x in 0...rep.pixelsWide {
            let drawn = x < rep.pixelsWide && (y0..<y1).contains { y in
                rgb(rep.colorAt(x: x, y: y)).map { differs($0, bg) } ?? false
            }
            if drawn, start == nil { start = x }
            if !drawn, let s = start {
                runs.append(CGFloat(s) / scale...CGFloat(x - 1) / scale)
                start = nil
            }
        }
        return runs
    }

    /// The band's pixel rows, one pixel in from each edge (a row's separator).
    private func pixelRows(_ band: CGRect) -> (Int, Int) {
        func py(_ y: CGFloat) -> Int {
            Int(((content.isFlipped ? y : content.bounds.height - y) * scale).rounded())
        }
        let a = py(band.minY), b = py(band.maxY)
        return (max(0, min(a, b) + 1), min(rep.pixelsHigh, max(a, b) - 1))
    }

    private func rgb(_ color: NSColor?) -> NSColor? { color?.usingColorSpace(.deviceRGB) }

    private func differs(_ a: NSColor, _ b: NSColor) -> Bool {
        abs(a.redComponent - b.redComponent) > 0.06
            || abs(a.greenComponent - b.greenComponent) > 0.06
            || abs(a.blueComponent - b.blueComponent) > 0.06
            || abs(a.alphaComponent - b.alphaComponent) > 0.06
    }
}

extension ClosedRange where Bound == CGFloat {
    var mid: CGFloat { (lowerBound + upperBound) / 2 }
}

// MARK: - Probes

@MainActor
private struct AlignmentBinderProbe: View {
    let store: ProjectStore
    let treeState: BinderTreeSectionsState
    @State private var subject = WindowSubject.book

    var body: some View {
        TreeHostFixture.binder(store: store, subject: $subject, treeState: treeState)
    }
}

@MainActor
private struct AlignmentCollectionProbe: View {
    let store: ProjectStore
    let treeState: BinderTreeSectionsState
    @State private var subject = WindowSubject.book
    @State private var renaming: String?

    var body: some View {
        TreeHostFixture.collection(store: store, subject: $subject,
                             renamingItemId: $renaming, treeState: treeState)
    }
}

/// A plain sidebar header beside one wearing `treeSectionTitle()`.
@MainActor
private struct HeaderStyleProbe: View {
    var body: some View {
        List {
            Section { Text("row") } header: { Text("Editions") }
            Section { Text("row") } header: { Text("Editions").treeSectionTitle() }
        }
        .listStyle(.sidebar)
    }
}
