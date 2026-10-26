import XCTest
import AppKit
import SwiftUI
import MaughamCore
@testable import Maugham

/// **A table figure's card expands in place into its grid, and folds back**
/// (report plan 7c Task 6). A mounted `EditorSurface` over a real novel, its
/// table figure, the window's real figure cards and the production
/// `FigureGridOpening`. Driven through the coordinator's verbs (expand,
/// fold), the real key path for Return (R7c-3), Insert ▸ Table as the menu
/// posts it, and ONE synchronous double-click (tripwire 33's
/// `clickRepresentatives`); the rest of the gesture is the pure
/// `FigureCardHit`. Nothing presses and waits: the visit's opening is awaited
/// through its handle (`FigureGridExpansion.opening`).
@MainActor
final class FigureGridExpandTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        FontWarmup.ensure()
    }

    private var temp: TempDirectory!
    private var documentStores: [DocumentStore] = []
    private var coordinators: [EditorCoordinator] = []

    override func setUp() async throws { temp = TempDirectory() }

    override func tearDown() async throws {
        for c in coordinators {
            if let controller = c.figureGrid?.controller {
                await controller.settleWrites()
                controller.close()
            }
        }
        coordinators = []
        for ds in documentStores { await ds.close() }
        documentStores.removeAll()
        temp.cleanup()
        temp = nil
    }

    // MARK: - Fixture

    final class Box {
        var text: String
        var reported: [String] = []
        init(_ text: String) { self.text = text }
    }

    struct Mounted {
        let box: Box
        let window: KeyTestWindow
        let textView: NSTextView
        let coordinator: EditorCoordinator
        let store: ProjectStore
        let cards: FigureCardCache
        let figure: FigureRecord?
        var text: NSString { textView.string as NSString }
    }

    /// Forty paragraphs of prose, the table's line, a paragraph, the SAME
    /// table written on a second line (R7c-4), and an end.
    static let document: String = {
        let prose = (1...40).map { "Paragraph \($0) of plain prose before the table." }
        return (prose + ["![Cash](../figures/t.csv){#tbl:t}", "Middle prose.",
                         "![Cash again](../figures/t.csv)", "The end."]).joined(separator: "\n\n")
    }()

    /// A novel, a `rows`×3 table figure `t` in its chapter, the window's
    /// figure cards filled, and a manuscript editor over `text` wired as
    /// `EditorHost` wires it.
    private func mount(_ text: String = document, rows: Int = 3, makeFigure: Bool = true,
                       height: CGFloat = 500,
                       beforeMaking: (@MainActor () -> Void)? = nil) async throws -> Mounted {
        let url = try await ProjectFactory.createNovelProject(
            named: "Novel-\(UUID().uuidString.prefix(6))", in: temp.url)
        let store = try await ProjectStore.load(from: url)
        let ds = try await DocumentStore.open(url: store.url)
        store.documentStore = ds
        ds.projectStore = store
        documentStores.append(ds)
        let chapter = try XCTUnwrap(store.manifest.structure.first)
        let path = try XCTUnwrap(chapter.path)
        let figure = makeFigure
            ? try await store.createFigure(kind: .table, name: "t", piece: chapter.id, rows: rows, columns: 3)
            : nil
        let cards = FigureCardCache()
        ds.attachFigureCardCache(cards)
        cards.attach(FigureCardCache.Source(read: { [weak ds] in await ds?.figureCardInputs() }))
        addTeardownBlock { @MainActor in
            cards.attach(nil)
            ds.detachFigureCardCache(cards)
        }
        await cards.idle()

        let box = Box(text)
        var configuration = EditorSurfaceConfiguration(
            presentation: .init(theme: .light, typography: .defaults,
                                mode: ProseMode(reservesFigureThumbnails: true),
                                typewriterScroll: false, sentenceFocus: false,
                                paragraphFocus: false, showElementGutter: false),
            control: EditorControl())
        configuration.answersInsertCommands = true
        configuration.paragraphProviders.figureImageResolver = { _ in .notLocal }
        configuration.paragraphProviders.figureCardModel = { cards.model(forLinePath: $0, documentPath: path) }
        configuration.paragraphProviders.figureGridOpening = .window(store: ds, projectStore: store, documentPath: path)
        configuration.paragraphProviders.tableFigureMaker = { request in
            beforeMaking?()   // the writer, while the figure is being made
            return try await FigureIngest.makeTableFigure(documentId: chapter.id, documentPath: path,
                                                   request: request, store: store)
        }
        configuration.paragraphProviders.commandFailureReporter = { box.reported.append($0) }
        let window = TestWindow.mount(
            EditorSurface(text: Binding(get: { box.text }, set: { box.text = $0 }), configuration: configuration),
            size: CGSize(width: 700, height: height), as: KeyTestWindow.self)
        addTeardownBlock { @MainActor in
            window.reportsKey = false
            window.close()
        }
        let textView = try XCTUnwrap(Self.textView(in: window.contentView))
        let coordinator = try XCTUnwrap(textView.delegate as? EditorCoordinator)
        coordinators.append(coordinator)
        window.makeFirstResponder(textView)
        return Mounted(box: box, window: window, textView: textView, coordinator: coordinator,
                       store: store, cards: cards, figure: figure)
    }

    private static func textView(in view: NSView?) -> NSTextView? {
        guard let view else { return nil }
        if let tv = view as? NSTextView { return tv }
        for sub in view.subviews { if let tv = textView(in: sub) { return tv } }
        return nil
    }

    private func location(_ m: Mounted, _ needle: String) -> Int {
        m.text.range(of: needle).location
    }

    private func spacing(_ m: Mounted, at location: Int) -> CGFloat {
        (m.textView.textStorage?.attribute(.paragraphStyle, at: location, effectiveRange: nil)
            as? NSParagraphStyle)?.paragraphSpacing ?? -1
    }

    private func cardRoom(_ m: Mounted) -> CGFloat {
        FigureCardMetrics.room(for: m.cards.model(forFigureId: m.figure?.id ?? ""), typography: .defaults)
    }

    private func scrollOrigin(_ m: Mounted) -> CGPoint {
        m.textView.enclosingScrollView?.contentView.bounds.origin ?? .zero
    }

    /// The bottom of the line holding `location`'s text, in text-view coordinates.
    private func lineBottom(_ m: Mounted, at location: Int) -> CGFloat {
        let lm = m.textView.layoutManager!
        var start = 0, end = 0, contentsEnd = 0
        m.text.getLineStart(&start, end: &end, contentsEnd: &contentsEnd, for: NSRange(location: location, length: 0))
        let glyph = lm.glyphIndexForCharacter(at: contentsEnd - 1)
        return lm.lineFragmentUsedRect(forGlyphAt: glyph, effectiveRange: nil).maxY + m.textView.textContainerOrigin.y
    }

    private func lineEnd(_ m: Mounted, at location: Int) -> Int {
        var start = 0, end = 0, contentsEnd = 0
        m.text.getLineStart(&start, end: &end, contentsEnd: &contentsEnd, for: NSRange(location: location, length: 0))
        return contentsEnd
    }

    /// The caret placed and the figure line scrolled into view, as the writer left them.
    private func park(_ m: Mounted, caret: Int, showing line: Int) {
        m.textView.setSelectedRange(NSRange(location: caret, length: 0))
        m.textView.scrollRangeToVisible(NSRange(location: line, length: 1))
        m.textView.layoutManager?.ensureLayout(for: m.textView.textContainer!)
    }

    private func opened(_ m: Mounted) async throws -> FigureGridExpansion {
        let grid = try XCTUnwrap(m.coordinator.figureGrid, "the card expanded")
        await grid.opening?.value
        XCTAssertNotNil(grid.controller, "the visit opened")
        return grid
    }

    // MARK: - Pure: the card hit and the panel's geometry

    /// A card is the room under its line, across the column: a point on the
    /// line's own text, past the room on the next line, or outside the
    /// column is no card's.
    func test_aCardHitIsTheRoomUnderItsLine_neverItsTextOrTheNextLine() {
        let card = FigureCardHit.Card(
            lineLocation: 120,
            frame: FigureCardHit.frame(lineBottom: 300, room: 80, columnX: 40, columnWidth: 500))
        let other = FigureCardHit.Card(
            lineLocation: 400,
            frame: FigureCardHit.frame(lineBottom: 600, room: 50, columnX: 40, columnWidth: 500))
        let cards = [card, other]
        XCTAssertEqual(FigureCardHit.line(at: CGPoint(x: 200, y: 301), in: cards), 120, "the card's top")
        XCTAssertEqual(FigureCardHit.line(at: CGPoint(x: 539, y: 379), in: cards), 120, "the card's far corner")
        XCTAssertNil(FigureCardHit.line(at: CGPoint(x: 200, y: 290), in: cards), "the line's own text")
        XCTAssertNil(FigureCardHit.line(at: CGPoint(x: 200, y: 381), in: cards), "the next line, past the room")
        XCTAssertNil(FigureCardHit.line(at: CGPoint(x: 20, y: 340), in: cards), "outside the column")
        XCTAssertEqual(FigureCardHit.line(at: CGPoint(x: 200, y: 620), in: cards), 400)
    }

    /// R7c-2: the room is the bars and min(rows, 15) rows; constant from 15
    /// rows up. The panel stacks the bars and the grid inside it, top to bottom.
    func test_theRoomIsTheBarsAndUpToFifteenRows_andThePanelStacksInsideIt() {
        let row = FigureCardMetrics.rowHeight(for: .defaults)
        let three = FigureGridPanel.room(rows: 3, typography: .defaults)
        XCTAssertEqual(three, 2 * FigureGridPanel.gap + FigureGridBars.totalHeight + 4 * row)
        XCTAssertEqual(FigureGridPanel.room(rows: 15, typography: .defaults) - three, 12 * row)
        XCTAssertEqual(FigureGridPanel.room(rows: 40, typography: .defaults),
                       FigureGridPanel.room(rows: 15, typography: .defaults), "constant from 15 rows up")

        let frame = FigureGridPanel.frame(lineBottom: 100, room: three, columnX: 30, columnWidth: 600)
        XCTAssertEqual(frame, CGRect(x: 30, y: 100 + FigureGridPanel.gap, width: 600,
                                     height: three - 2 * FigureGridPanel.gap))
        let parts = FigureGridPanel.parts(in: frame.size)
        XCTAssertEqual(parts.toolbar.minY, 0)
        XCTAssertEqual(parts.formulaBar.minY, parts.toolbar.maxY)
        XCTAssertEqual(parts.grid.minY, parts.formulaBar.maxY)
        XCTAssertEqual(parts.grid.height, FigureGridLayout.viewportHeight(rows: 3, rowHeight: row),
                       "the grid gets exactly its viewport")
        XCTAssertEqual(parts.bottomBar.minY, parts.grid.maxY)
        XCTAssertEqual(parts.bottomBar.maxY, frame.height)
    }

    /// A whole-buffer replace is followed through a line diff: a kept line
    /// answers itself, a rewritten one what replaced it, a removed one
    /// nothing — even when the same figure is written on another line.
    func test_aLineIsFollowedThroughAWholeReplace() {
        let old = "A\n\n![T](t.csv)\n\nB\n\n![T2](t.csv)"
        let line = (old as NSString).range(of: "![T]").location

        let above = "A longer\nopening\n\n![T](t.csv)\n\nB\n\n![T2](t.csv)"
        XCTAssertEqual(FigureGridLineFollow.follow(lineStart: line, old: old, new: above),
                       (above as NSString).range(of: "![T](t.csv)"), "kept: the same line, moved")

        let renamed = "A\n\n![T](cash.csv){#tbl:cash}\n\nB\n\n![T2](cash.csv)"
        let within = FigureGridLineFollow.follow(lineStart: line, old: old, new: renamed)
        XCTAssertTrue(NSLocationInRange((renamed as NSString).range(of: "![T](cash").location, within),
                      "rewritten: looked for in what replaced it")
        XCTAssertFalse(NSLocationInRange((renamed as NSString).range(of: "![T2]").location, within),
                       "never the other line")

        let adjacent = "A\n\n![T](t.csv)\n\n![T2](t.csv)"
        let afterAdjacent = "A\n\n![T2](t.csv)"
        XCTAssertEqual(FigureGridLineFollow.follow(
            lineStart: (adjacent as NSString).range(of: "![T]").location, old: adjacent, new: afterAdjacent).length,
                       0, "removed beside the same figure's line: still nothing replaced it")

        let removed = "A\n\nB\n\n![T2](t.csv)"
        let gone = FigureGridLineFollow.follow(lineStart: line, old: old, new: removed)
        XCTAssertEqual(gone.length, 0, "removed: nothing replaced it")
        XCTAssertFalse(NSLocationInRange((removed as NSString).range(of: "![T2]").location, gone))
    }

    // MARK: - Expand and fold

    /// **Expand, then fold**: only that paragraph re-lays out each way
    /// (counted), the caret and the scroll stay where they are, the same
    /// figure's other line keeps its card (R7c-4), the overlay draws no card
    /// under the expanded line, the grid is a subview of the text view at the
    /// line's bottom holding the focus, the text around it dimmed by a view
    /// that takes no click. Folded, the card is back and the caret is at the
    /// end of the figure line.
    func test_expandThenFoldReLaysOutOnlyThatParagraph_caretAndScrollStill() async throws {
        let m = try await mount()
        let line = location(m, "![Cash](")
        let other = location(m, "![Cash again]")
        let body = spacing(m, at: location(m, "Middle prose"))
        XCTAssertEqual(spacing(m, at: line) - body, cardRoom(m), "premise: the card's room")
        let caret = location(m, "Middle prose") + 3
        park(m, caret: caret, showing: line)
        let origin = scrollOrigin(m)
        let refreshes = m.coordinator.figureRoomRefreshCount
        let room = FigureGridPanel.room(rows: 3, typography: .defaults)

        XCTAssertTrue(m.coordinator.expandFigureGrid(lineAt: line + 4))

        XCTAssertEqual(m.coordinator.figureRoomRefreshCount - refreshes, 1, "only that paragraph re-laid out")
        XCTAssertEqual(spacing(m, at: line) - body, room, "the line holds the grid's room")
        XCTAssertEqual(spacing(m, at: other) - body, cardRoom(m), "the other line keeps its card (R7c-4)")
        XCTAssertEqual(m.textView.selectedRange(), NSRange(location: caret, length: 0), "the caret is still")
        XCTAssertEqual(scrollOrigin(m), origin, "the scroll is still")

        let grid = try await opened(m)
        let panel = try XCTUnwrap(grid.panel)
        XCTAssertTrue(panel.superview === m.textView, "the grid is a real subview of the text view")
        XCTAssertEqual(panel.frame.minY, lineBottom(m, at: line) + FigureGridPanel.gap, accuracy: 0.5,
                       "framed at the line's bottom")
        XCTAssertEqual(panel.frame.height, room - 2 * FigureGridPanel.gap, accuracy: 0.5)
        XCTAssertTrue(m.window.firstResponder === grid.controller?.gridView, "the grid has the focus")
        XCTAssertTrue(grid.dim.superview === m.textView)
        XCTAssertNil(grid.dim.hitTest(CGPoint(x: 10, y: 10)), "the dimming takes no click")
        XCTAssertGreaterThan(grid.dim.hole.height, room, "the line and its room are left undimmed")
        let overlay = try XCTUnwrap(m.coordinator.figureThumbnailOverlay)
        overlay.display()
        XCTAssertEqual(overlay.lastVisibleFigureCount - overlay.lastDrawn.count, 1,
                       "no card is drawn under the expanded line")

        let folding = m.coordinator.figureRoomRefreshCount
        m.coordinator.foldFigureGrid(commit: true)

        XCTAssertNil(m.coordinator.figureGrid)
        XCTAssertEqual(m.coordinator.figureRoomRefreshCount - folding, 1, "only that paragraph re-laid out")
        XCTAssertEqual(spacing(m, at: line) - body, cardRoom(m), "the card's room is back")
        XCTAssertNil(panel.superview)
        XCTAssertNil(grid.dim.superview)
        XCTAssertEqual(m.textView.selectedRange(), NSRange(location: lineEnd(m, at: line), length: 0),
                       "the caret returns to the end of the figure line")
        XCTAssertTrue(m.window.firstResponder === m.textView)
        XCTAssertEqual(scrollOrigin(m), origin, "the fold scrolls nothing")
        overlay.display()
        XCTAssertEqual(overlay.lastVisibleFigureCount, overlay.lastDrawn.count, "every card is drawn again")
    }

    /// Done in the bottom bar folds through the controller's model and the
    /// coordinator's one teardown.
    func test_doneFolds() async throws {
        let m = try await mount()
        let line = location(m, "![Cash](")
        XCTAssertTrue(m.coordinator.expandFigureGrid(lineAt: line))
        let grid = try await opened(m)
        grid.controller?.perform(.done)
        XCTAssertNil(m.coordinator.figureGrid)
        XCTAssertNil(grid.panel?.superview)
        XCTAssertTrue(m.window.firstResponder === m.textView)
    }

    /// Not a table figure's line, nothing expands; expanding the other line
    /// of the same figure folds the first and expands only the second (R7c-4).
    func test_onlyATableLineExpands_andOnlyOneLineAtATime() async throws {
        let m = try await mount()
        XCTAssertFalse(m.coordinator.expandFigureGrid(lineAt: location(m, "Middle prose")))
        XCTAssertNil(m.coordinator.figureGrid)
        let first = location(m, "![Cash](")
        let second = location(m, "![Cash again]")
        let body = spacing(m, at: location(m, "Middle prose"))
        XCTAssertTrue(m.coordinator.expandFigureGrid(lineAt: first))
        _ = try await opened(m)
        XCTAssertTrue(m.coordinator.expandFigureGrid(lineAt: second))
        XCTAssertEqual(m.coordinator.figureGrid?.lineLocation, second)
        XCTAssertEqual(spacing(m, at: first) - body, cardRoom(m), "the first folded back to its card")
        XCTAssertEqual(spacing(m, at: second) - body, FigureGridPanel.room(rows: 3, typography: .defaults))
    }

    // MARK: - Gestures

    /// **The double-click, through the real entry point** (the one click
    /// representative): `MaughamTextView.mouseDown(with:)` with a click count
    /// of two inside the card expands it — synchronously, the room already
    /// grown when the call returns.
    func test_aDoubleClickOnTheCardExpandsIt() async throws {
        let m = try await mount()
        let line = location(m, "![Cash](")
        park(m, caret: 0, showing: line)
        let inCard = CGPoint(x: m.textView.textContainerOrigin.x + 40, y: lineBottom(m, at: line) + 10)
        let down = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDown, location: m.textView.convert(inCard, to: nil), modifierFlags: [],
            timestamp: 0, windowNumber: m.window.windowNumber, context: nil, eventNumber: 0,
            clickCount: 2, pressure: 1))

        m.textView.mouseDown(with: down)

        XCTAssertEqual(m.coordinator.figureGrid?.lineLocation, line, "the card under the click expanded")
        // This one event is the second click only. In a real double-click the
        // first (clickCount 1) reaches `super`, which puts the caret on the
        // line under the card; the fold puts it back when the grid had the focus.
        XCTAssertEqual(m.textView.selectedRange(), NSRange(location: 0, length: 0), "the second click moved no caret")
        _ = try await opened(m)
    }

    /// **R7c-3, on the real key path**: Return inside a table figure's line
    /// expands it and writes nothing; Return at the line's end inserts a
    /// newline as it always has.
    func test_returnInsideTheLineExpands_returnAtItsEndInsertsANewline() async throws {
        let m = try await mount()
        let line = location(m, "![Cash](")
        let text = m.textView.string
        m.textView.setSelectedRange(NSRange(location: line + 3, length: 0))
        m.window.sendEvent(returnKey(m))
        XCTAssertEqual(m.coordinator.figureGrid?.lineLocation, line, "Return inside the line expanded it")
        XCTAssertEqual(m.textView.string, text, "and wrote nothing")
        _ = try await opened(m)
        m.coordinator.foldFigureGrid(commit: true)

        let end = lineEnd(m, at: line)
        m.textView.setSelectedRange(NSRange(location: end, length: 0))
        m.window.sendEvent(returnKey(m))
        XCTAssertNil(m.coordinator.figureGrid, "Return at the line's end expands nothing")
        XCTAssertEqual(m.text.substring(with: NSRange(location: end, length: 1)), "\n", "it inserts a newline")
        XCTAssertEqual(m.textView.string.count, text.count + 1)
    }

    private func returnKey(_ m: Mounted) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                         windowNumber: m.window.windowNumber, context: nil, characters: "\r",
                         charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!
    }

    /// **Insert ▸ Table lands expanded** (spec §6.4): the menu's post, the
    /// figure made and its line written, then its grid open on that line.
    func test_insertTableLandsExpanded() async throws {
        let m = try await mount("Intro", makeFigure: false)
        m.textView.setSelectedRange(NSRange(location: 5, length: 0))
        m.coordinator.tableFigureTask = nil
        MaughamEvent.post(.maughamInsertTable, to: .keyWindow)
        await m.coordinator.tableFigureTask?.value

        XCTAssertEqual(m.textView.string, "Intro\n\n![Caption](../figures/table.csv){#tbl:table}")
        let made = try XCTUnwrap(m.store.manifest.figures?.first)
        let grid = try await opened(m)
        XCTAssertEqual(grid.figureId, made.id)
        XCTAssertEqual(grid.lineLocation, location(m, "![Caption]"), "on the line just written")
        XCTAssertTrue(grid.panel?.superview === m.textView)
        XCTAssertEqual(m.box.reported, [])
    }

    // MARK: - Following the line

    /// **Review Focus 5**: renamed while expanded — its line relabelled
    /// through `applyExternalText` — the grid stays open on the same figure
    /// and line; the line deleted elsewhere — the grid folds, even though the
    /// same figure is still written on another line.
    func test_renamedTheGridStaysOpen_lineDeletedTheGridFolds() async throws {
        let m = try await mount()
        let line = location(m, "![Cash](")
        XCTAssertTrue(m.coordinator.expandFigureGrid(lineAt: line))
        let grid = try await opened(m)
        let figureId = try XCTUnwrap(m.figure?.id)

        _ = try await m.store.renameFigure(id: figureId, to: "cash")
        let relabelled = m.textView.string
            .replacingOccurrences(of: "../figures/t.csv", with: "../figures/cash.csv")
            .replacingOccurrences(of: "{#tbl:t}", with: "{#tbl:cash}")
        m.coordinator.applyExternalText(relabelled)

        XCTAssertTrue(m.coordinator.figureGrid === grid, "the grid stays open")
        XCTAssertEqual(grid.figureId, figureId)
        XCTAssertEqual(grid.lineLocation, location(m, "![Cash](../figures/cash.csv)"))
        XCTAssertTrue(grid.panel?.superview === m.textView)
        let body = spacing(m, at: location(m, "Middle prose"))
        XCTAssertEqual(spacing(m, at: grid.lineLocation) - body, grid.room, "the room stays on the line")

        let deleted = m.textView.string.replacingOccurrences(of: "![Cash](../figures/cash.csv){#tbl:cash}\n\n", with: "")
        m.coordinator.applyExternalText(deleted)

        XCTAssertNil(m.coordinator.figureGrid, "the line is gone: the grid folds")
        XCTAssertNil(grid.panel?.superview)
    }

    /// **Review M1**: the expanded line deleted where the next line is the
    /// same figure's — the grid folds; it never hops onto that line.
    func test_aDeletedLineBesideTheSameFiguresLineFolds() async throws {
        let m = try await mount("Opening.\n\n![Cash](../figures/t.csv){#tbl:t}\n\n![Again](../figures/t.csv)\n\nEnd.")
        XCTAssertTrue(m.coordinator.expandFigureGrid(lineAt: location(m, "![Cash](")))
        _ = try await opened(m)
        m.coordinator.applyExternalText(
            m.textView.string.replacingOccurrences(of: "![Cash](../figures/t.csv){#tbl:t}\n\n", with: ""))
        XCTAssertNil(m.coordinator.figureGrid, "the line is gone: the grid folds")
    }

    /// Two table figure lines, the expanded one BELOW the other, in a window
    /// tall enough that the text view's height never changes (so no resize
    /// re-frames the grid by accident).
    private static let figureAbove =
        "Opening.\n\n![Above](../figures/t.csv)\n\nMiddle prose.\n\n![Cash](../figures/t.csv){#tbl:t}\n\nEnd."

    private func assertFramedAtItsLine(_ m: Mounted, _ grid: FigureGridExpansion, _ message: String,
                                       file: StaticString = #filePath, line: UInt = #line) {
        let panel = grid.panel?.frame ?? .null
        let bottom = lineBottom(m, at: grid.lineLocation)
        XCTAssertEqual(panel.minY, bottom + FigureGridPanel.gap, accuracy: 0.5, message, file: file, line: line)
        XCTAssertEqual(grid.dim.hole.maxY, bottom + grid.room, accuracy: 0.5, "the dimming's hole follows",
                       file: file, line: line)
    }

    /// **Review I1 (a)**: a relabel through `applyExternalText` resets every
    /// room and the paint puts them back; the grid is framed after that
    /// paint, at its line's new bottom.
    func test_aRelabelUnderAFigureAboveReFramesTheGridAfterThePaint() async throws {
        let m = try await mount(Self.figureAbove, height: 1400)
        XCTAssertTrue(m.coordinator.expandFigureGrid(lineAt: location(m, "![Cash](")))
        let grid = try await opened(m)
        _ = try await m.store.renameFigure(id: try XCTUnwrap(m.figure?.id), to: "cash")
        m.coordinator.applyExternalText(m.textView.string
            .replacingOccurrences(of: "../figures/t.csv", with: "../figures/cash.csv")
            .replacingOccurrences(of: "{#tbl:t}", with: "{#tbl:cash}"))
        XCTAssertTrue(m.coordinator.figureGrid === grid, "premise: still open")
        assertFramedAtItsLine(m, grid, "framed at the line's bottom after the paint")
    }

    /// **Review I1 (b)**: a card edge that grows the card ABOVE the grid
    /// (the same table's other line, R7c-4) moves the grid's line down; the
    /// grid follows.
    func test_aCardGrowingAboveTheGridMovesTheGridWithItsLine() async throws {
        let m = try await mount(Self.figureAbove, height: 1400)
        XCTAssertTrue(m.coordinator.expandFigureGrid(lineAt: location(m, "![Cash](")))
        let grid = try await opened(m)
        let height = m.textView.frame.height
        let host = try XCTUnwrap(grid.controller?.host)
        _ = try await host.insertRow(after: host.state.table.rows.last!, undoManager: nil)
        await m.store.documentStore?.settleFigureCards()
        await m.cards.idle()
        let before = grid.panel?.frame.minY ?? 0

        m.coordinator.setFigureCardVersion(m.cards.version)

        XCTAssertEqual(m.textView.frame.height, height, "premise: no resize re-framed it")
        XCTAssertGreaterThan(grid.panel?.frame.minY ?? 0, before, "the line moved down")
        assertFramedAtItsLine(m, grid, "and the grid with it")
    }

    // MARK: - Insert ▸ Table and the writer

    /// **Review I2 ruling**: a writer who moved on while the table was made
    /// (typed during the make) keeps the focus — the line lands as a card,
    /// deferred, and nothing expands.
    func test_insertTableForAWriterWhoMovedOnLandsAsACard() async throws {
        var textView: NSTextView?
        let m = try await mount("Intro", makeFigure: false, beforeMaking: {
            guard let textView else { return }
            textView.insertText(" more", replacementRange: NSRange(location: 5, length: 0))
        })
        textView = m.textView
        m.textView.setSelectedRange(NSRange(location: 5, length: 0))
        m.coordinator.tableFigureTask = nil
        MaughamEvent.post(.maughamInsertTable, to: .keyWindow)
        await m.coordinator.tableFigureTask?.value

        XCTAssertTrue(m.textView.string.contains("![Caption](../figures/table.csv){#tbl:table}"),
                      "the line landed: \(m.textView.string)")
        XCTAssertTrue(m.textView.string.contains("Intro more"), "premise: the writer typed during the make")
        XCTAssertNil(m.coordinator.figureGrid, "a writer who moved on is not taken into a grid")
        XCTAssertTrue(m.window.firstResponder === m.textView, "and keeps the focus")
    }

    /// Insert ▸ Table straight after typing (a burst's settle still pending,
    /// the writer still there) expands; the room lands with the settle and
    /// the grid is framed at the line.
    func test_insertTableDuringATypingBurstExpands() async throws {
        let m = try await mount("", makeFigure: false)
        m.textView.setSelectedRange(NSRange(location: 0, length: 0))
        m.textView.insertText("Intro", replacementRange: NSRange(location: 0, length: 0))
        XCTAssertTrue(m.coordinator.isInTypingBurst, "premise: a burst is in flight")
        m.coordinator.tableFigureTask = nil
        MaughamEvent.post(.maughamInsertTable, to: .keyWindow)
        await m.coordinator.tableFigureTask?.value

        let grid = try await opened(m)
        XCTAssertEqual(grid.lineLocation, location(m, "![Caption]"))
        await m.coordinator.deferredRestyleTask?.value   // the burst's settle
        let line = location(m, "![Caption]")
        let body = spacing(m, at: 0)
        XCTAssertEqual(spacing(m, at: line) - body, grid.room, "the room is on the line after the settle")
        assertFramedAtItsLine(m, grid, "framed at the line")
    }

    /// An edit above the expanded line carries its anchor: the grid stays on
    /// its line, re-framed at its new bottom.
    func test_typingAboveTheLineCarriesTheAnchor() async throws {
        let m = try await mount()
        let line = location(m, "![Cash](")
        XCTAssertTrue(m.coordinator.expandFigureGrid(lineAt: line))
        let grid = try await opened(m)
        let edit = location(m, "Paragraph 40")
        XCTAssertTrue(m.coordinator.applyCommandEdit(
            replacing: NSRange(location: edit, length: 0), with: "A new line.\n\n",
            selecting: NSRange(location: edit, length: 0), actionName: "Test"))

        XCTAssertEqual(grid.lineLocation, location(m, "![Cash]("), "the anchor rode the edit")
        XCTAssertTrue(m.coordinator.figureGrid === grid)
        XCTAssertEqual(grid.panel?.frame.minY ?? 0, lineBottom(m, at: grid.lineLocation) + FigureGridPanel.gap,
                       accuracy: 0.5, "re-framed at the line's new bottom")
    }

    /// **R7c-2 at a commit edge**: the table grew a row; at the next
    /// `figureCardVersion` edge the room grows to hold it, re-laying out
    /// that line only.
    func test_theRoomGrowsAtACardEdgeWhenTheTableGrows() async throws {
        let m = try await mount("Opening.\n\n![Cash](../figures/t.csv){#tbl:t}\n\nMiddle prose.")
        let line = location(m, "![Cash](")
        XCTAssertTrue(m.coordinator.expandFigureGrid(lineAt: line))
        let grid = try await opened(m)
        let host = try XCTUnwrap(grid.controller?.host)
        _ = try await host.insertRow(after: host.state.table.rows.last!, undoManager: nil)
        await m.store.documentStore?.settleFigureCards()
        await m.cards.idle()
        let refreshes = m.coordinator.figureRoomRefreshCount
        let body = spacing(m, at: location(m, "Middle prose"))

        m.coordinator.setFigureCardVersion(m.cards.version)

        XCTAssertEqual(grid.room, FigureGridPanel.room(rows: 4, typography: .defaults))
        XCTAssertEqual(spacing(m, at: line) - body, grid.room)
        XCTAssertEqual(m.coordinator.figureRoomRefreshCount - refreshes, 1, "that line only")
        XCTAssertEqual(grid.panel?.frame.height ?? 0, grid.room - 2 * FigureGridPanel.gap, accuracy: 0.5)
    }
}
