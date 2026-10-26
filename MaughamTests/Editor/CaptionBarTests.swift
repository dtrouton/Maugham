import XCTest
import AppKit
import MaughamCore
@testable import Maugham

/// **The caption bar** (report plan 7b Task 8, spec §3.2, R7b-1, R7b-2): a
/// figure line's syntax is painted faint — blended toward the background,
/// never an alpha — and shown again only while the caret is on the line, by
/// a layout-manager temporary that never edits the storage; "Table 2." /
/// "Figure 3." is drawn beside the line by the label overlay. No synthesised
/// event (tripwire 33): the caret is moved with `setSelectedRange`.
@MainActor
final class CaptionBarTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        FontWarmup.ensure()   // styles through ProseMode
    }

    /// Records every storage edit its layout manager hears (as
    /// `FigureRoomRefreshTests` measures re-layout).
    private final class CountingLayoutManager: NSLayoutManager {
        var edits = 0
        override func processEditing(
            for textStorage: NSTextStorage, edited editMask: NSTextStorageEditActions,
            range newCharRange: NSRange, changeInLength delta: Int, invalidatedRange invalidatedCharRange: NSRange
        ) {
            edits += 1
            super.processEditing(for: textStorage, edited: editMask, range: newCharRange,
                                 changeInLength: delta, invalidatedRange: invalidatedCharRange)
        }
    }

    /// `count` figure lines, alternating table and image, between prose.
    private static func document(figures count: Int) -> String {
        var parts = ["Opening paragraph of plain prose."]
        for i in 0..<count {
            parts.append(i.isMultiple(of: 2)
                ? "![Table \(i)](figures/t\(i).csv){#tbl:t\(i)}"
                : "![Image \(i)](figures/i\(i).png)")
            parts.append("Paragraph \(i) of prose under it.")
        }
        return parts.joined(separator: "\n\n")
    }

    private static let index = ReferenceIndex.build(
        pieces: [("before", ReferenceIndex.PieceSummary(
            text: "![A](figures/a.csv)\n\n![B](b.png){#fig:b}\n\n![C](c.png)")),
                 ("this", .empty)],
        research: [], words: .english).versioned(1)

    /// A manuscript editor as `EditorHost` wires one, laid out in full, its
    /// layout manager counting storage edits.
    private func mount(_ text: String, numbers: Bool = true,
                       counting: Bool = false) -> (EditorIntegrationHarness, CountingLayoutManager?) {
        let harness = EditorIntegrationHarness(
            mode: ProseMode(reservesFigureThumbnails: true), initialText: text, cursorLocation: 0)
        harness.coordinator.figureImageResolver = { _ in .notLocal }
        harness.coordinator.answersInsertCommands = true
        harness.coordinator.referenceIndex = { Self.index }
        if numbers {
            harness.coordinator.figureNumbersBefore = { Self.index.numbersBefore(docId: "this") }
        }
        harness.coordinator.attach(to: harness.textView)   // a whole-document paint
        var layout: CountingLayoutManager?
        if counting {
            let counter = CountingLayoutManager()
            harness.textView.textContainer!.replaceLayoutManager(counter)
            layout = counter
        }
        let container = harness.textView.textContainer!
        container.size = NSSize(width: container.size.width, height: .greatestFiniteMagnitude)
        harness.textView.isVerticallyResizable = true
        harness.textView.layoutManager!.ensureLayout(for: container)
        harness.textView.sizeToFit()
        layout?.edits = 0
        return (harness, layout)
    }

    private func colours(_ harness: EditorIntegrationHarness) -> (faded: NSColor, shown: NSColor) {
        ProseMode.figureSyntaxColours(ProseMode.palette(for: harness.coordinator.theme))
    }

    private func stored(_ harness: EditorIntegrationHarness, at location: Int) -> NSColor? {
        harness.textView.textStorage!.attribute(.foregroundColor, at: location, effectiveRange: nil) as? NSColor
    }

    private func temporary(_ harness: EditorIntegrationHarness, at location: Int) -> NSColor? {
        harness.textView.layoutManager!.temporaryAttribute(
            .foregroundColor, atCharacterIndex: location, effectiveRange: nil) as? NSColor
    }

    /// Every run of temporary foreground colour over the whole text.
    private func temporaryRuns(_ harness: EditorIntegrationHarness) -> [NSRange] {
        let lm = harness.textView.layoutManager!
        let length = harness.textView.textStorage!.length
        var out: [NSRange] = []
        var at = 0
        while at < length {
            var run = NSRange()
            let value = lm.temporaryAttribute(.foregroundColor, atCharacterIndex: at,
                                              longestEffectiveRange: &run,
                                              in: NSRange(location: 0, length: length))
            if value != nil { out.append(run) }
            at = max(NSMaxRange(run), at + 1)
        }
        return out
    }

    /// `ranges` with touching neighbours joined, as a run of one colour reads.
    private func merged(_ ranges: [NSRange]) -> [NSRange] {
        var out: [NSRange] = []
        for range in ranges.sorted(by: { $0.location < $1.location }) {
            if let last = out.last, NSMaxRange(last) >= range.location {
                out[out.count - 1] = NSUnionRange(last, range)
            } else {
                out.append(range)
            }
        }
        return out
    }

    // MARK: - R7b-2: the paint

    /// The figure line's `![`, `](path)` and `{#…}` are painted the faded
    /// colour — opaque, `syntaxPunctuation` blended toward the background —
    /// on image and table lines alike; the caption stays body text; a
    /// heading's label keeps the plain syntax colour; a research note (no
    /// thumbnails) paints no fade.
    func test_figureLineSyntaxIsPaintedBlendedTowardTheBackground() {
        let text = "# Heading {#sec:h}\n\n![Cash](figures/cash.csv){#tbl:cash}\n\n![Map](map.png)"
        let ns = text as NSString
        let (harness, _) = mount(text)
        let (faded, shown) = colours(harness)
        XCTAssertEqual(faded.alphaComponent, 1, "a blend, never an alpha (R7b-2)")
        XCTAssertNotEqual(faded, shown)
        for needle in ["![Cash]", "](figures/cash.csv)", "{#tbl:cash}", "![Map]", "](map.png)"] {
            let at = ns.range(of: needle).location + (needle.hasPrefix("![") ? 0 : 1)
            XCTAssertEqual(stored(harness, at: at), faded, needle)
        }
        XCTAssertNotEqual(stored(harness, at: ns.range(of: "Cash]").location), faded,
                          "the caption is prose")
        XCTAssertEqual(stored(harness, at: ns.range(of: "{#sec:h}").location), shown,
                       "a heading's label is not figure syntax")

        let note = NSTextStorage(string: text)
        let prose = ProseMode()
        prose.applyTypography(in: note, theme: harness.coordinator.theme, typography: .defaults,
                              tokens: prose.tokenize(text), wikiLinkResolver: nil)
        XCTAssertEqual(note.attribute(.foregroundColor, at: ns.range(of: "![Map]").location,
                                      effectiveRange: nil) as? NSColor, shown,
                       "a research note draws no caption bar")
    }

    /// The trap R7b-2 names: the focus dim sets alpha 0.4 absolutely, so a
    /// fade done by alpha would come out BRIGHTER when dimmed. The blended
    /// colour, dimmed, sits no further from the background than undimmed.
    func test_theFocusDimNeverBrightensAFadedLine() throws {
        let text = "Prose in focus here.\n\n![Map](map.png)\n\nMore prose."
        let (harness, _) = mount(text)
        let at = (text as NSString).range(of: "![Map]").location
        let faded = try XCTUnwrap(stored(harness, at: at))
        harness.coordinator.applyFocusPrefs(sentence: false, paragraph: true)
        harness.setCursor(to: 3)   // the first paragraph has the focus
        let dimmed = try XCTUnwrap(stored(harness, at: at))
        XCTAssertLessThan(dimmed.alphaComponent, 1, "premise: the figure line is dimmed")
        let background = ProseMode.palette(for: harness.coordinator.theme).background
        func distance(_ c: NSColor) -> CGFloat {
            let a = c.usingColorSpace(.sRGB)!, b = background.usingColorSpace(.sRGB)!
            // `c` composited over the background, against the background.
            let mix = { (x: CGFloat, y: CGFloat) in x * a.alphaComponent + y * (1 - a.alphaComponent) }
            return abs(mix(a.redComponent, b.redComponent) - b.redComponent)
                + abs(mix(a.greenComponent, b.greenComponent) - b.greenComponent)
                + abs(mix(a.blueComponent, b.blueComponent) - b.blueComponent)
        }
        XCTAssertLessThanOrEqual(distance(dimmed), distance(faded),
                                 "dimming a faded line makes it fainter, never brighter")
    }

    // MARK: - Review Focus 3: arrow the caret through 20 figure lines

    func test_arrowingThroughTwentyFigureLinesUnfadesOnlyTheCaretsLine() throws {
        let text = Self.document(figures: 20)
        let (harness, counter) = mount(text, counting: true)
        let layout = try XCTUnwrap(counter)
        let coordinator = harness.coordinator
        let lines = coordinator.figureCaptionLines
        XCTAssertEqual(lines.count, 20)
        let shown = colours(harness).shown
        let origin = harness.scrollView.contentView.bounds.origin
        let length = harness.textView.textStorage!.length
        XCTAssertEqual(layout.firstUnlaidCharacterIndex(), length, "premise: laid out in full")
        XCTAssertTrue(temporaryRuns(harness).isEmpty, "the caret starts on prose")

        for (i, line) in lines.enumerated() {
            harness.setCursor(to: line.lineRange.location + 3)
            XCTAssertEqual(temporaryRuns(harness), merged(line.syntax),
                           "line \(i): only its own syntax is shown")
            for range in line.syntax { XCTAssertEqual(temporary(harness, at: range.location), shown) }
            let moves = coordinator.figureSyntaxUnfadeMoves
            harness.setCursor(to: NSMaxRange(line.lineRange))   // along the same line
            XCTAssertEqual(coordinator.figureSyntaxUnfadeMoves, moves, "a move along a line moves nothing")
            harness.setCursor(to: NSMaxRange(line.lineRange) + 2)   // onto the prose below
            XCTAssertTrue(temporaryRuns(harness).isEmpty, "line \(i): left, it fades again")
        }
        XCTAssertEqual(coordinator.figureSyntaxUnfadeWholeClears, 0,
                       "a caret move never clears the whole text's temporaries")
        XCTAssertEqual(layout.edits, 0, "a caret move makes no storage edit")
        XCTAssertEqual(layout.firstUnlaidCharacterIndex(), length, "and invalidates no layout")
        XCTAssertEqual(harness.scrollView.contentView.bounds.origin, origin, "and does not scroll")
    }

    /// Typing on the caret's line moves its syntax; the settle shows the
    /// syntax where it now is and leaves nothing behind. The stale
    /// temporaries are cleared over the whole text at most once per
    /// character edit (whole-branch review M2).
    func test_typingOnTheCaretsLineIsShownWhereItLandsAtTheSettle() async throws {
        let text = "Opening prose.\n\n![Cash](figures/cash.csv){#tbl:cash}\n\nClosing prose."
        let (harness, _) = mount(text)
        harness.coordinator.restyleSettleDelayMs = 0
        harness.setCursor(to: (text as NSString).range(of: "Cash]").location + 4)
        let clears = harness.coordinator.figureSyntaxUnfadeWholeClears
        await harness.typeString(" flows")
        await harness.coordinator.deferredRestyleTask?.value
        let made = harness.coordinator.figureSyntaxUnfadeWholeClears - clears
        XCTAssertGreaterThan(made, 0, "the edit's stale temporaries were cleared")
        XCTAssertLessThanOrEqual(made, " flows".count, "at most once per character edit")
        let line = try XCTUnwrap(harness.coordinator.figureCaptionLine(
            at: (harness.currentText as NSString).range(of: "Cash flows").location))
        XCTAssertEqual(temporaryRuns(harness), merged(line.syntax), "exactly the line's syntax, where it is now")
    }

    // MARK: - Translation review

    /// Translation review shows no caret line (its dimming owns the
    /// temporary foreground and clears it over the whole text); leaving it
    /// shows the caret's line again, and the dimming leaves nothing behind.
    func test_translationReviewLeavesNoStrayTemporaryAndTheDimmingClearsExactly() {
        let text = "![Cash](figures/cash.csv){#tbl:cash}\n\nMissing paragraph."
        let ns = text as NSString
        let (harness, _) = mount(text)
        let coordinator = harness.coordinator
        harness.setCursor(to: 3)
        let syntax = coordinator.figureCaptionLines[0].syntax
        XCTAssertEqual(temporaryRuns(harness), merged(syntax), "premise: the caret's line is shown")

        coordinator.setTranslationReview(true)
        XCTAssertTrue(temporaryRuns(harness).isEmpty, "entering, the un-fade goes")
        let missing = ns.range(of: "Missing paragraph.")
        coordinator.resolvedTranslationBadges = [.init(paragraphId: "a", range: missing, status: .missing)]
        coordinator.applyTranslationDimming()
        harness.setCursor(to: 5)   // a caret move in review adds nothing
        XCTAssertEqual(temporaryRuns(harness), [missing], "only the dimming")

        coordinator.setTranslationReview(false)
        coordinator.applyTranslationDimming()   // leaving: the dimming clears
        XCTAssertEqual(temporaryRuns(harness), merged(syntax), "only the caret's line, shown again")
    }

    // MARK: - R7b-1: the number

    /// "Table n." / "Figure n." beside each line: the index's numbers before
    /// this document plus the line's ordinal, an unlabelled `.csv` line a
    /// Table; drawn in the margin at a wide inset.
    func test_theNumberIsDrawnInTheMarginWithTheBooksNumber() throws {
        let text = "![X](figures/x.csv)\n\n![Y](y.png){#fig:y}\n\n| a |\n|---|\n| 1 |\n\n![Z](figures/z.csv){#tbl:z}"
        let (harness, _) = mount(text)
        harness.textView.textContainerInset = NSSize(width: 120, height: 24)
        let overlay = try XCTUnwrap(harness.coordinator.referenceLabelOverlay)
        overlay.frame = harness.textView.bounds
        overlay.display()
        XCTAssertEqual(overlay.lastCaptionTexts, ["Table 2.", "Figure 3.", "Table 4."],
                       "before: one table, two figures; then X, Y, the pipe table, Z")
        XCTAssertEqual(overlay.lastMarginNumberCount, 3)
        XCTAssertEqual(overlay.lastCaptionTagCount, 0)
    }

    /// An empty caption (`![](…)`, what Convert writes for an uncaptioned
    /// table) draws its number as legibly as a captioned line's: in the
    /// body's ink, never sampled off the faded `]` (whole-branch review M2).
    func test_anEmptyCaptionsNumberIsAsLegibleAsACaptionedOne() throws {
        let text = "![Cash](figures/cash.csv){#tbl:cash}\n\n![](figures/bare.csv){#tbl:bare}\n\nProse."
        let (harness, _) = mount(text)
        harness.setCursor(to: (text as NSString).length)   // neither line shown
        harness.textView.textContainerInset = NSSize(width: 120, height: 24)
        let overlay = try XCTUnwrap(harness.coordinator.referenceLabelOverlay)
        overlay.frame = harness.textView.bounds
        overlay.display()
        XCTAssertEqual(overlay.lastCaptionTexts, ["Table 2.", "Table 3."])
        let inks = overlay.lastMarginNumberInks
        XCTAssertEqual(inks.count, 2)
        XCTAssertEqual(inks.first, inks.last, "the bare line's number is drawn like the captioned one's")
        let faded = colours(harness).faded
        XCTAssertNotEqual(inks.last, faded.withAlphaComponent(faded.alphaComponent * 0.55),
                          "not the faded syntax's colour")
    }

    /// A margin too narrow for the number falls back to the tag above the
    /// line, shown for the caret or the pointer only.
    func test_aNarrowMarginFallsBackToTheTagForTheCaret() throws {
        let text = "Prose first.\n\n![Map](map.png)"
        let (harness, _) = mount(text)
        harness.textView.textContainerInset = NSSize(width: 0, height: 24)
        let overlay = try XCTUnwrap(harness.coordinator.referenceLabelOverlay)
        overlay.display()
        XCTAssertEqual(overlay.lastMarginNumberCount, 0)
        XCTAssertEqual(overlay.lastCaptionTagCount, 0, "the caret is elsewhere")
        harness.setCursor(to: (text as NSString).range(of: "Map]").location)
        overlay.display()
        XCTAssertEqual(overlay.lastCaptionTagCount, 1)
        XCTAssertEqual(overlay.lastCaptionTexts, ["Figure 3."])
    }

    /// A caret move repaints the narrow-margin tags only when the caret
    /// enters or leaves a figure line, never along one or across prose
    /// (whole-branch review M2).
    func test_aCaretMoveRepaintsOnlyWhenItChangesFigureLine() throws {
        let text = "Prose first.\n\n![Map](map.png)\n\n![Cash](figures/cash.csv){#tbl:cash}\n\nProse last."
        let ns = text as NSString
        let (harness, _) = mount(text)
        harness.textView.textContainerInset = NSSize(width: 0, height: 24)
        let overlay = try XCTUnwrap(harness.coordinator.referenceLabelOverlay)
        overlay.display()
        XCTAssertEqual(overlay.lastMarginNumberCount, 0, "premise: the tags wait for the caret")
        func requests(_ move: () -> Void) -> Int {
            let before = overlay.repaintRequests
            move()
            return overlay.repaintRequests - before
        }
        XCTAssertEqual(requests { harness.setCursor(to: 3) }, 0, "across prose")
        XCTAssertEqual(requests { harness.setCursor(to: ns.range(of: "Map]").location) }, 1, "onto a line")
        XCTAssertEqual(requests { harness.setCursor(to: ns.range(of: "Map]").location + 2) }, 0,
                       "along the line")
        XCTAssertEqual(requests { harness.setCursor(to: ns.range(of: "Cash]").location) }, 1,
                       "onto another line")
        XCTAssertEqual(requests { harness.setCursor(to: ns.range(of: "last").location) }, 1, "off it")
        XCTAssertEqual(requests { harness.setCursor(to: ns.length) }, 0, "across prose again")
    }

    /// Before the index has read this document, no number is guessed.
    func test_noNumberBeforeTheIndexHasReadTheDocument() throws {
        let (harness, _) = mount("![Map](map.png)", numbers: false)
        harness.textView.textContainerInset = NSSize(width: 120, height: 24)
        let overlay = try XCTUnwrap(harness.coordinator.referenceLabelOverlay)
        overlay.display()
        XCTAssertEqual(overlay.lastMarginNumberCount + overlay.lastCaptionTagCount, 0)
    }

    func test_theMarginOriginRightAlignsToTheColumnOrGivesWay() {
        let point = ReferenceLabelLayout.marginOrigin(columnMinX: 100, viewMinX: 0, labelWidth: 40,
                                                      baseline: 50, ascender: 10)
        XCTAssertEqual(point, CGPoint(x: 100 - ReferenceLabelLayout.marginGap - 40, y: 40))
        XCTAssertNil(ReferenceLabelLayout.marginOrigin(columnMinX: 30, viewMinX: 0, labelWidth: 40,
                                                       baseline: 50, ascender: 10))
    }
}
