import XCTest
import AppKit
import MaughamCore
@testable import Maugham

/// **What a document full of table cards costs a keystroke** (report plan 7a
/// Task 7, ruling R7a-5). Fixture-free: the book is built in memory
/// (`FigureCardBook`), behind the real `FigureCardCache`, control plane and
/// coordinator.
///
/// The budget is COUNTERS, never a clock: during a burst of keystrokes in a
/// document of 30 table cards, the cache fills nothing, no figure line's
/// style is re-applied, the trailing card's room is never looked up again
/// and the cards are not asked at all — until the settle edge, which (with
/// no card changed) re-lays out nothing either. The one timed test is a
/// RATIO of a figure-heavy corpus to a plain one of the same prose, under a
/// generous ceiling, so a loaded gate cannot trip it.
@MainActor
final class FigureCardTypingBudgetTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        FontWarmup.ensure()   // styles through ProseMode
    }

    private final class Counter { var value = 0 }

    func test_aBurstAmongThirtyCardsFillsNothingAndRestylesNoFigureLineUntilTheSettle() async {
        let keystrokes = 60
        // Ends on a card, so the trailing room is in play on every keystroke.
        let rig = EditorIntegrationHarness(
            mode: ProseMode(reservesFigureThumbnails: true),
            initialText: FigureCardBook.manuscript(tables: 30, endsOnFigure: true), cursorLocation: 0)
        let book = FigureCardBook(tables: 30, rows: 5)
        let coordinator = rig.coordinator
        await book.wire(coordinator, documentPath: rig.docPath, textView: rig.textView)
        XCTAssertGreaterThan(coordinator.figureTrailingRoom, 0, "precondition: the last line is a card")
        let layout = EditRecordingLayoutManager.install(on: rig.textView)
        let lookups = Counter()
        let provide = coordinator.figureCardModel
        coordinator.figureCardModel = { lookups.value += 1; return provide?($0) }
        func figureLines() -> [NSRange] { (0..<30).map { rig.nsText.range(of: FigureCardBook.line($0)) } }

        let reads = book.reads, refreshes = coordinator.figureRoomRefreshCount
        let trailingLookups = coordinator.trailingFigureRoomLookupCount
        coordinator.restyleSettleDelayMs = 3_600_000   // the settle waits for the test
        rig.setCursor(to: NSMaxRange(rig.nsText.range(of: "Paragraph 12 of prose under its table")))
        rig.assertNoApplyExternalText {
            for i in 0..<keystrokes { rig.typeCharacter(i % 6 == 5 ? " " : "x") }
        }
        XCTAssertTrue(coordinator.isInTypingBurst, "precondition: still in the burst")

        XCTAssertEqual(book.reads - reads, 0, "\(keystrokes) keystrokes: the cache fills nothing")
        XCTAssertEqual(coordinator.figureRoomRefreshCount - refreshes, 0, "no figure line re-laid out")
        XCTAssertEqual(layout.styleEdits(touching: figureLines()), [],
                       "no figure line's style re-applied by a keystroke")
        XCTAssertEqual(coordinator.trailingFigureRoomLookupCount - trailingLookups, 0,
                       "the trailing card's room is memoised: no keystroke looks it up")
        XCTAssertEqual(lookups.value, 0, "no keystroke asks the cards at all")
        XCTAssertEqual(layout.edits.filter(\.charactersChanged).count, keystrokes,
                       "control: every keystroke reached the layout manager")

        // The settle edge: one paint of the burst's paragraph. No card moved,
        // so it fills nothing and re-lays out no figure line either.
        coordinator.restyleSettleDelayMs = 0
        rig.typeCharacter(".")
        await coordinator.deferredRestyleTask?.value
        XCTAssertEqual(book.reads - reads, 0, "the settle fills nothing")
        XCTAssertEqual(coordinator.figureRoomRefreshCount - refreshes, 0)
        XCTAssertEqual(layout.styleEdits(touching: figureLines()), [],
                       "the settle paints the typed paragraph, not a figure line")
        XCTAssertEqual(coordinator.trailingFigureRoomLookupCount - trailingLookups, 0)
        XCTAssertTrue(layout.edits.contains { !$0.charactersChanged },
                      "control: the settle did paint (an attribute-only edit reached the layout manager)")
    }

    /// The paint's cost RATIO, figure-heavy over plain: the same prose, once
    /// with a table figure line after every second paragraph (each a
    /// filled card), tokenized and painted whole (`ProseMode.tokenize` +
    /// `applyTypography` with the coordinator's room function). A card line
    /// costs a path parse, a memory lookup and a style; a ratio past the
    /// ceiling means a figure line started paying for something per paint
    /// (a disk read, a fill, a re-resolution per token). Measured on the dev
    /// machine (Debug, test host), 2026-10-25, 129 cards in ~60 KB: plain
    /// ≈ 4.7 ms, figure-heavy ≈ 8.9 ms, ratio ≈ 1.9. With the registry
    /// re-standardised per record on every lookup (before
    /// `FigureLineResolution.Index`): 28.8 ms, ratio ≈ 6.0, which trips it.
    func test_aFigureHeavyCorpusPaintsWithinAGenerousRatioOfPlainProse() async {
        let paragraphs = TypingLatencyProbeTests.generateProse(bytes: 60_000)
            .components(separatedBy: "\n\n").filter { !$0.isEmpty }
        let figures = paragraphs.count / 2
        var heavy: [String] = []
        for (i, p) in paragraphs.enumerated() {
            heavy.append(p)
            if i % 2 == 1, i / 2 < figures { heavy.append(FigureCardBook.line(i / 2)) }
        }
        let plainText = paragraphs.joined(separator: "\n\n")
        let heavyText = heavy.joined(separator: "\n\n")

        let book = FigureCardBook(tables: figures, rows: 8)
        book.cache.attach(book.source)
        await book.cache.idle()
        let cache = book.cache
        XCTAssertEqual(cache.model(forLinePath: "../figures/t0.csv", documentPath: "manuscript/a.md")?.kind,
                       .table, "precondition: the cards are filled")
        let room: (String) -> CGFloat = {
            FigureCardMetrics.room(for: cache.model(forLinePath: $0, documentPath: "manuscript/a.md"),
                                   typography: .defaults)
        }

        let mode = ProseMode(reservesFigureThumbnails: true)
        let clock = ContinuousClock()
        func ms(_ text: String) -> Double {
            let storage = NSTextStorage(string: text)
            let t = clock.now
            mode.applyTypography(in: storage, theme: .light, typography: .defaults,
                                 tokens: mode.tokenize(text), wikiLinkResolver: nil, figureRoom: room)
            let d = clock.now - t
            return Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
        }
        _ = ms(plainText); _ = ms(heavyText)
        var plain = Double.infinity, figureHeavy = Double.infinity
        for _ in 0..<7 {   // fastest of seven, interleaved: load only ever adds time
            plain = min(plain, ms(plainText))
            figureHeavy = min(figureHeavy, ms(heavyText))
        }
        let ratio = figureHeavy / plain
        XCTAssertLessThan(ratio, 3,
            "\(figures) table cards made the paint \(ratio)× plain prose's (\(plain) ms → \(figureHeavy) ms)")
    }
}
