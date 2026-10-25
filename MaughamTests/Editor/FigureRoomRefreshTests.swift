import XCTest
import AppKit
import MaughamCore
@testable import Maugham

/// **A card's version re-lays out only the lines whose room moved** (report
/// plan 7a Task 5). When the window's figure cards change
/// (`EditorControl.figureCardVersion` → `setFigureCardVersion`), the
/// coordinator asks every figure line its room again and restyles only the
/// lines whose room differs: one `addAttribute(.paragraphStyle)` per line,
/// never mid-burst (the settle paint runs it), no caret move, no scroll snap.
///
/// Ruling R7a-5: what is re-laid out is MEASURED, through a layout manager
/// that records every `processEditing` the storage sends it, never asserted
/// from reasoning. What it pins: one attribute-only edit over exactly the
/// changed line; TextKit 1 (contiguous layout) then holds the text laid out
/// up to that line, and lays out everything after it again, lazily, the next
/// time layout is asked for.
@MainActor
final class FigureRoomRefreshTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        FontWarmup.ensure()   // styles through ProseMode
    }

    /// Records the storage's edits as each layout manager hears them.
    private final class CountingLayoutManager: NSLayoutManager {
        struct Edit: Equatable {
            let charactersChanged: Bool
            let range: NSRange
            let invalidated: NSRange
        }
        var edits: [Edit] = []
        override func processEditing(
            for textStorage: NSTextStorage, edited editMask: NSTextStorageEditActions,
            range newCharRange: NSRange, changeInLength delta: Int, invalidatedRange invalidatedCharRange: NSRange
        ) {
            edits.append(Edit(charactersChanged: editMask.contains(.editedCharacters),
                              range: newCharRange, invalidated: invalidatedCharRange))
            super.processEditing(for: textStorage, edited: editMask, range: newCharRange,
                                 changeInLength: delta, invalidatedRange: invalidatedCharRange)
        }
    }

    /// The cards the provider answers, changed by the test between versions.
    private final class Cards {
        var byPath: [String: FigureCardModel] = [:]
    }

    private static func table(rows: Int) -> FigureCardModel {
        let shown = min(rows, 12)
        return FigureCardModel(kind: .table, bodyRows: Array(repeating: ["1"], count: shown),
                               moreRows: rows - shown)
    }

    private static func room(_ model: FigureCardModel?) -> CGFloat {
        FigureCardMetrics.room(for: model, typography: .defaults)
    }

    /// `count` table figure lines, each between two prose paragraphs.
    private static func document(tables count: Int) -> String {
        var parts = ["Opening paragraph of plain prose."]
        for i in 0..<count {
            parts.append("![Table \(i)](figures/t\(i).csv){#tbl:t\(i)}")
            parts.append("Paragraph \(i) of prose under its table.")
        }
        parts.append("Closing paragraph.")
        return parts.joined(separator: "\n\n")
    }

    private struct Fixture {
        let harness: EditorIntegrationHarness
        let cards: Cards
        let layout: CountingLayoutManager
        var storage: NSTextStorage { harness.textView.textStorage! }
        var text: NSString { harness.textView.string as NSString }
    }

    /// A manuscript editor over `text` whose figure cards come from `cards`,
    /// painted whole, laid out in full, with a counting layout manager.
    private func mount(_ text: String, cards: Cards) -> Fixture {
        let harness = EditorIntegrationHarness(
            mode: ProseMode(reservesFigureThumbnails: true), initialText: text, cursorLocation: 0)
        harness.coordinator.figureImageResolver = { _ in .notLocal }
        harness.coordinator.figureCardModel = { cards.byPath[$0] }
        harness.coordinator.attach(to: harness.textView)   // a whole-document paint
        let layout = CountingLayoutManager()
        let container = harness.textView.textContainer!
        container.replaceLayoutManager(layout)
        // A container as tall as the text, as the editor's own is, so every
        // line lays out and the view scrolls.
        container.size = NSSize(width: container.size.width, height: .greatestFiniteMagnitude)
        harness.textView.isVerticallyResizable = true
        layout.ensureLayout(for: container)
        harness.textView.sizeToFit()
        layout.edits.removeAll()
        return Fixture(harness: harness, cards: cards, layout: layout)
    }

    private func spacing(_ f: Fixture, at needle: String) -> CGFloat {
        let at = f.text.range(of: needle).location
        return (f.storage.attribute(.paragraphStyle, at: at, effectiveRange: nil) as? NSParagraphStyle)?
            .paragraphSpacing ?? -1
    }

    private func lineRange(_ f: Fixture, of needle: String) -> NSRange {
        f.text.lineRange(for: NSRange(location: f.text.range(of: needle).location, length: 0))
    }

    private func lineTop(_ f: Fixture, of needle: String) -> CGFloat {
        let lm = f.harness.textView.layoutManager!
        let glyph = lm.glyphIndexForCharacter(at: f.text.range(of: needle).location)
        return lm.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).minY
    }

    /// Every paragraph-style run of `storage`, to compare two paints.
    private func paragraphStyles(_ storage: NSTextStorage) -> [(NSRange, NSParagraphStyle?)] {
        var out: [(NSRange, NSParagraphStyle?)] = []
        storage.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: storage.length)) {
            value, range, _ in out.append((range, value as? NSParagraphStyle))
        }
        return out
    }

    // MARK: - Review Focus 2: a table grows from 3 to 40 rows

    func test_aGrowingTableReLaysOutItsOwnLineOnceAndTheTextBelowMovesDown() {
        let cards = Cards()
        for i in 0..<5 { cards.byPath["figures/t\(i).csv"] = Self.table(rows: 3) }
        let f = mount(Self.document(tables: 5), cards: cards)
        let body = spacing(f, at: "Opening")
        XCTAssertEqual(spacing(f, at: "![Table 2]"), body + Self.room(Self.table(rows: 3)),
                       "precondition: the three-row card's room")
        let selection = NSRange(location: 3, length: 0)
        f.harness.textView.setSelectedRange(selection)
        let below = lineTop(f, of: "Paragraph 2 of prose")
        let farBelow = lineTop(f, of: "Closing paragraph")
        let above = lineTop(f, of: "Paragraph 1 of prose")

        cards.byPath["figures/t2.csv"] = Self.table(rows: 40)
        f.harness.coordinator.setFigureCardVersion(1)

        let grown = Self.room(Self.table(rows: 40))
        XCTAssertEqual(spacing(f, at: "![Table 2]"), body + grown)
        XCTAssertEqual(spacing(f, at: "{#tbl:t2}"), body + grown, "the whole line carries it")
        for other in ["![Table 0]", "![Table 1]", "![Table 3]", "![Table 4]"] {
            XCTAssertEqual(spacing(f, at: other), body + Self.room(Self.table(rows: 3)), other)
        }
        XCTAssertEqual(f.harness.coordinator.figureRoomRefreshCount, 1)
        // R7a-5, measured: ONE attribute-only edit, over exactly that line.
        XCTAssertEqual(f.layout.edits, [CountingLayoutManager.Edit(
            charactersChanged: false, range: lineRange(f, of: "![Table 2]"),
            invalidated: lineRange(f, of: "![Table 2]"))])
        // Layout before the line is kept; from the line on it lays out again.
        XCTAssertEqual(f.layout.firstUnlaidCharacterIndex(), lineRange(f, of: "![Table 2]").location,
                       "contiguous TextKit 1 holds the text above and re-lays out from the line on")
        XCTAssertEqual(f.harness.textView.selectedRange(), selection, "the caret never moves")
        XCTAssertEqual(lineTop(f, of: "Paragraph 1 of prose"), above, "text above stays put")
        let delta = grown - Self.room(Self.table(rows: 3))
        XCTAssertEqual(lineTop(f, of: "Paragraph 2 of prose"), below + delta, accuracy: 0.5,
                       "text below moves down by the room the card gained")
        XCTAssertEqual(lineTop(f, of: "Closing paragraph"), farBelow + delta, accuracy: 0.5)

        // The refreshed text equals a whole-document paint with the same cards.
        let whole = mount(Self.document(tables: 5), cards: cards)
        let refreshed = paragraphStyles(f.storage), painted = paragraphStyles(whole.storage)
        XCTAssertEqual(refreshed.map(\.0), painted.map(\.0))
        for (a, b) in zip(refreshed, painted) {
            XCTAssertTrue(a.1?.isEqual(b.1) ?? (b.1 == nil), "paragraph style at \(a.0)")
        }
    }

    /// A card whose values changed but whose height did not re-lays out
    /// nothing: no storage edit reaches the layout manager.
    func test_aCardWhoseRoomDidNotMoveReLaysOutNothing() {
        let cards = Cards()
        cards.byPath["figures/t0.csv"] = Self.table(rows: 3)
        let f = mount(Self.document(tables: 2), cards: cards)
        cards.byPath["figures/t0.csv"] = FigureCardModel(
            kind: .table, bodyRows: Array(repeating: ["2"], count: 3))
        f.harness.coordinator.setFigureCardVersion(1)
        XCTAssertEqual(f.layout.edits, [])
        XCTAssertEqual(f.harness.coordinator.figureRoomRefreshCount, 0)
    }

    /// The first fill (R7a-2): every line that was a cache miss and is now a
    /// table card re-lays out; an image stays as it was.
    func test_theFirstFillReLaysOutTheMissesThatBecameCards() {
        let cards = Cards()
        let f = mount(Self.document(tables: 3) + "\n\n![Logo](figures/logo.png)", cards: cards)
        cards.byPath["figures/t0.csv"] = Self.table(rows: 5)
        cards.byPath["figures/t2.csv"] = Self.table(rows: 1)
        cards.byPath["figures/logo.png"] = .placeholder(.image)
        f.harness.coordinator.setFigureCardVersion(1)
        XCTAssertEqual(f.harness.coordinator.figureRoomRefreshCount, 2, "two lines restyled")
        XCTAssertEqual(spacing(f, at: "![Table 1]"),
                       spacing(f, at: "Opening") + FigureThumbnailLayout.reservedHeight,
                       "a line still missing keeps the placeholder")
        // Measured (R7a-5): the two lines are restyled in ONE editing
        // bracket, so the storage reports one attribute-only edit spanning
        // from the first to the last; contiguous layout re-lays out
        // everything from the first line on in any case.
        let first = lineRange(f, of: "![Table 0]"), last = lineRange(f, of: "![Table 2]")
        XCTAssertEqual(f.layout.edits, [CountingLayoutManager.Edit(
            charactersChanged: false, range: NSUnionRange(first, last),
            invalidated: NSUnionRange(first, last))])
    }

    /// The version guard (D2): the same version twice does the work once.
    func test_theSameVersionTwiceDoesNothingTheSecondTime() {
        let cards = Cards()
        let f = mount(Self.document(tables: 1), cards: cards)
        cards.byPath["figures/t0.csv"] = Self.table(rows: 5)
        f.harness.coordinator.setFigureCardVersion(1)
        cards.byPath["figures/t0.csv"] = Self.table(rows: 9)
        f.harness.coordinator.setFigureCardVersion(1)
        XCTAssertEqual(spacing(f, at: "![Table 0]"),
                       spacing(f, at: "Opening") + Self.room(Self.table(rows: 5)))
        XCTAssertEqual(f.layout.edits.count, 1)
    }

    // MARK: - Review Focus 1: a change lands mid-burst

    func test_aChangeMidBurstWaitsForTheSettleThenReLaysOutOnce() async {
        let cards = Cards()
        for i in 0..<30 { cards.byPath["figures/t\(i).csv"] = Self.table(rows: 3) }
        let f = mount(Self.document(tables: 30), cards: cards)
        let coordinator = f.harness.coordinator
        coordinator.restyleSettleDelayMs = 0   // the settle runs on the next main-actor turn
        let body = spacing(f, at: "Opening")
        let target = "![Table 17]"
        let typeAt = NSMaxRange(f.text.range(of: "Paragraph 3 of prose under its table"))
        f.harness.setCursor(to: typeAt)
        f.harness.assertNoApplyExternalText {
            for c in " and" { f.harness.typeCharacter(c) }
            XCTAssertTrue(coordinator.isInTypingBurst, "precondition: the burst is in flight")
            cards.byPath["figures/t17.csv"] = Self.table(rows: 40)
            coordinator.setFigureCardVersion(1)
            for c in " more" { f.harness.typeCharacter(c) }
        }
        XCTAssertEqual(spacing(f, at: target), body + Self.room(Self.table(rows: 3)),
                       "mid-burst the figure line keeps its painted room")
        XCTAssertEqual(coordinator.figureRoomRefreshCount, 0)
        XCTAssertTrue(f.layout.edits.allSatisfy(\.charactersChanged),
                      "the keystrokes are the only storage edits during the burst")
        let caret = f.harness.cursorLocation
        XCTAssertEqual(caret, typeAt + (" and more" as NSString).length)

        await coordinator.deferredRestyleTask?.value   // the settle edge
        XCTAssertEqual(spacing(f, at: target), body + Self.room(Self.table(rows: 40)))
        XCTAssertEqual(coordinator.figureRoomRefreshCount, 1, "once, after the burst")
        XCTAssertFalse(coordinator.figureRoomsWaitForTheSettle)
        let figureEdits = f.layout.edits.filter { !$0.charactersChanged
            && NSIntersectionRange($0.range, self.lineRange(f, of: target)).length > 0 }
        XCTAssertEqual(figureEdits.map(\.range), [lineRange(f, of: target)])
        XCTAssertEqual(f.harness.cursorLocation, caret, "the settle leaves the caret where it was")
        for i in [0, 16, 18, 29] {
            XCTAssertEqual(spacing(f, at: "![Table \(i)]"), body + Self.room(Self.table(rows: 3)), "\(i)")
        }
    }

    /// No scroll snap: a re-layout above the visible text leaves the clip's
    /// origin where it was.
    func test_aReLayoutLeavesTheScrollOriginAlone() {
        let cards = Cards()
        let f = mount(Self.document(tables: 30), cards: cards)
        let tv = f.harness.textView
        let clip = f.harness.scrollView.contentView
        clip.scroll(to: NSPoint(x: 0, y: lineTop(f, of: "Paragraph 25 of prose")))
        f.harness.scrollView.reflectScrolledClipView(clip)
        let origin = clip.bounds.origin
        XCTAssertGreaterThan(origin.y, 0, "precondition: scrolled down")
        cards.byPath["figures/t3.csv"] = Self.table(rows: 40)
        cards.byPath["figures/t28.csv"] = Self.table(rows: 40)
        f.harness.coordinator.setFigureCardVersion(1)
        XCTAssertEqual(f.harness.coordinator.figureRoomRefreshCount, 2, "precondition: both re-laid out")
        tv.layoutManager!.ensureLayout(for: tv.textContainer!)
        XCTAssertEqual(clip.bounds.origin, origin)
    }

    // MARK: - The storage observers ignore an attribute-only edit

    func test_theStorageObserversIgnoreTheReLayout() {
        let cards = Cards()
        let f = mount(Self.document(tables: 3), cards: cards)
        let point = f.text.range(of: "Paragraph 2 of prose").location
        let table = TableAnchorTracker(anchor: point, storage: f.storage)
        let figure = FigureAnchorTracker(anchor: FigureIngest.Anchor(point: point, in: f.text as String),
                                         storage: f.storage)
        defer { table.stop(); figure.stop() }
        let figureBefore = figure.anchor
        cards.byPath["figures/t0.csv"] = Self.table(rows: 40)
        f.harness.coordinator.setFigureCardVersion(1)
        XCTAssertEqual(f.harness.coordinator.figureRoomRefreshCount, 1, "precondition: it re-laid out")
        XCTAssertEqual(table.anchor, point)
        XCTAssertEqual(figure.anchor, figureBefore)
        XCTAssertFalse(f.harness.coordinator.tokensDescribeAnEarlierText,
                       "the coordinator's own observer did not mark the tokens stale")

        // The control: a character edit above the anchors moves them.
        f.storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "X")
        XCTAssertEqual(table.anchor, point + 1)
        XCTAssertNotEqual(figure.anchor, figureBefore)
        XCTAssertTrue(f.harness.coordinator.tokensDescribeAnEarlierText)
    }

    // MARK: - A table card on the last line

    private final class Box { var text: String; init(_ t: String) { text = t } }

    func test_aTrailingTableKeepsItsRoomAsItGrowsAndGivesItBackAsItShrinks() {
        let cards = Cards()
        cards.byPath["figures/t0.csv"] = Self.table(rows: 3)
        let text = (0..<12).map { "Paragraph \($0) of plain prose." }.joined(separator: "\n\n")
            + "\n\n![Last](figures/t0.csv){#tbl:t0}"
        let tv = MaughamTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 300))
        _ = tv.layoutManager   // TextKit 1, as EditorSurface.makeNSView pins it
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.textContainer?.widthTracksTextView = true
        tv.string = text
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: 300))
        scroll.documentView = tv
        let window = TestWindow.make(contentRect: NSRect(x: 0, y: 0, width: 600, height: 300),
                                     contentView: scroll, present: .unshown)
        defer { window.close() }
        let box = Box(text)
        let coordinator = EditorCoordinator(
            text: .init(get: { box.text }, set: { box.text = $0 }),
            mode: ProseMode(reservesFigureThumbnails: true),
            theme: .light, typography: .defaults, typewriterScroll: false,
            sentenceFocus: false, paragraphFocus: false)
        coordinator.figureImageResolver = { _ in .notLocal }
        coordinator.figureCardModel = { cards.byPath[$0] }
        tv.delegate = coordinator
        tv.coordinator = coordinator
        coordinator.attach(to: tv)
        tv.layoutManager?.ensureLayout(for: tv.textContainer!)
        tv.sizeToFit()

        func needed(_ room: CGFloat) -> CGFloat {
            let lm = tv.layoutManager!
            let last = lm.glyphIndexForCharacter(at: (tv.string as NSString).length - 1)
            return lm.lineFragmentUsedRect(forGlyphAt: last, effectiveRange: nil).maxY
                + tv.textContainerOrigin.y + room + tv.textContainerInset.height
        }
        XCTAssertEqual(coordinator.figureTrailingRoom, Self.room(Self.table(rows: 3)),
                       "the trailing room is the card's own")
        XCTAssertGreaterThanOrEqual(tv.frame.height, needed(Self.room(Self.table(rows: 3))))

        cards.byPath["figures/t0.csv"] = Self.table(rows: 40)
        coordinator.setFigureCardVersion(1)
        tv.layoutManager?.ensureLayout(for: tv.textContainer!)   // layout only; no sizeToFit here
        let grown = Self.room(Self.table(rows: 40))
        XCTAssertEqual(coordinator.figureTrailingRoom, grown)
        XCTAssertGreaterThanOrEqual(tv.frame.height, needed(grown), "the grown card fits in the frame")

        cards.byPath["figures/t0.csv"] = Self.table(rows: 3)
        coordinator.setFigureCardVersion(2)
        tv.layoutManager?.ensureLayout(for: tv.textContainer!)
        XCTAssertGreaterThanOrEqual(tv.frame.height, needed(Self.room(Self.table(rows: 3))))
        XCTAssertLessThan(tv.frame.height, needed(grown), "the shrunk card gives its room back")
    }
}
