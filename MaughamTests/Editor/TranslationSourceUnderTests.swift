import XCTest
import AppKit
import MaughamCore
@testable import Maugham

/// **A piece read in a language, its source under each paragraph** (shell p4
/// Task 8). The surface is one derived, read-only buffer: each paragraph's
/// translation, then its source in quieter ink, blocks joined as ever. The
/// badges and the caret keep meaning "this paragraph" because a badge range
/// covers the translation alone and a caret in a source line belongs to its
/// paragraph. Pure, plus one hand-pumped buffer swap through the one
/// external-text site.
final class TranslationSourceUnderTests: XCTestCase {

    /// a and b translated, c not.
    private func derived(stale: Bool = false) -> [TranslatedDocument.Entry] {
        let paragraphs = ["a": "One", "b": "Two", "c": "Three"]
        let records = [
            TranslationRecord(paragraphId: "a", language: "sr", text: "Jedan",
                              sourceHash: TranslationHash.hash("One")),
            TranslationRecord(paragraphId: "b", language: "sr", text: "Dva",
                              sourceHash: stale ? "STALE" : TranslationHash.hash("Two")),
        ]
        return TranslationDeriver.derive(records: records, sequence: ["a", "b", "c"],
                                         paragraphs: paragraphs, language: "sr").entries
    }

    private func slice(_ text: String, _ range: NSRange?) -> String? {
        range.map { (text as NSString).substring(with: $0) }
    }

    func test_eachBlockIsTheTranslationThenItsSource() {
        let entries = EditorHost.reviewBadgeEntries(from: derived(), showsSourceUnder: true)
        XCTAssertEqual(TranslationBadgeLayout.surface(entries: entries),
                       "Jedan\nOne\n\nDva\nTwo\n\nThree")
        XCTAssertEqual(entries.map(\.source), ["One", "Two", nil])
    }

    func test_theBadgeRangeCoversOnlyTheTranslation() {
        let entries = EditorHost.reviewBadgeEntries(from: derived(), showsSourceUnder: true)
        let surface = TranslationBadgeLayout.surface(entries: entries)
        let ranges = TranslationBadgeLayout.ranges(entries: entries)
        XCTAssertEqual(ranges.map { slice(surface, $0.range) }, ["Jedan", "Dva", "Three"])
        XCTAssertEqual(ranges.map { slice(surface, $0.sourceRange) }, ["One", "Two", nil])
        XCTAssertEqual(slice(surface, ranges[1].blockRange), "Dva\nTwo")
    }

    /// A click in the grey line under "Dva" is in paragraph b: the surface's
    /// own walk says so, the translation pane's says so, and the source caret
    /// it is told lands inside b's source paragraph — which is what To
    /// resolve's caret group, the Translator's note and the footer read.
    func test_theCaretInASourceLineSelectsItsParagraph() {
        let entries = EditorHost.reviewBadgeEntries(from: derived(), showsSourceUnder: true)
        let surface = TranslationBadgeLayout.surface(entries: entries) as NSString
        let inTwo = surface.range(of: "Two").location + 1   // inside the source line
        let ranges = TranslationBadgeLayout.ranges(entries: entries)
        XCTAssertEqual(TranslationBadgeLayout.index(at: inTwo, in: ranges).map { ranges[$0].paragraphId }, "b")
        // In b's grey line, not in its translation: what a landing scrolls to
        // and the badge marks is the translation alone.
        XCTAssertFalse(NSLocationInRange(inTwo, ranges[1].range))
        XCTAssertTrue(ranges[1].sourceRange.map { NSLocationInRange(inTwo, $0) } ?? false)
        // The source text "One\n\nTwo\n\nThree": b is 5..<8.
        let sourceRanges = ["a": NSRange(location: 0, length: 3), "b": NSRange(location: 5, length: 3),
                            "c": NSRange(location: 10, length: 5)]
        let told = TranslationBadgeLayout.sourceLocation(
            forSurfaceLocation: inTwo, ranges: ranges, sourceRangeOf: { sourceRanges[$0] })
        XCTAssertEqual(told, 6, "one character into the source line is one into b's source")
        // In the translation, the same paragraph, clamped into its source.
        let inDva = surface.range(of: "Dva").location + 2
        XCTAssertEqual(TranslationBadgeLayout.sourceLocation(
            forSurfaceLocation: inDva, ranges: ranges, sourceRangeOf: { sourceRanges[$0] }), 7)
        // A paragraph the source no longer has tells nothing.
        XCTAssertNil(TranslationBadgeLayout.sourceLocation(
            forSurfaceLocation: inTwo, ranges: ranges, sourceRangeOf: { _ in nil }))
    }

    /// **A remembered source caret lands in its own paragraph** of a chapter
    /// opened already read in a language — and comes back to the same
    /// paragraph when told to the source again.
    func test_aRememberedCaretLandsInItsOwnParagraphOfTheTranslation() {
        let entries = EditorHost.reviewBadgeEntries(from: derived(), showsSourceUnder: true)
        let ranges = TranslationBadgeLayout.ranges(entries: entries)
        let b = NSRange(location: 5, length: 3)   // "Two" in "One\n\nTwo\n\nThree"
        let surface = TranslationBadgeLayout.surfaceLocation(forSourceLocation: 6, paragraphId: "b",
                                                             sourceRange: b, ranges: ranges)
        XCTAssertEqual(surface, ranges[1].range.location + 1, "one into Dva")
        XCTAssertEqual(TranslationBadgeLayout.sourceLocation(
            forSurfaceLocation: surface ?? -1, ranges: ranges,
            sourceRangeOf: { $0 == "b" ? b : nil }), 6, "and back to the same place")
        XCTAssertNil(TranslationBadgeLayout.surfaceLocation(forSourceLocation: 6, paragraphId: "gone",
                                                            sourceRange: b, ranges: ranges))
    }

    /// No translation: the source shows ONCE, as the paragraph's text, dimmed
    /// as "not translated yet" — never twice, never a blank.
    func test_aMissingParagraphShowsItsSourceOnce() {
        let entries = EditorHost.reviewBadgeEntries(from: derived(), showsSourceUnder: true)
        let surface = TranslationBadgeLayout.surface(entries: entries)
        XCTAssertEqual(entries[2].text, "Three")
        XCTAssertNil(entries[2].source)
        XCTAssertEqual(surface.components(separatedBy: "Three").count - 1, 1)
        let inks = TranslationBadgeLayout.inks(TranslationBadgeLayout.ranges(entries: entries),
                                               length: (surface as NSString).length)
        XCTAssertEqual(inks.filter { !$0.isSource }.map { slice(surface, $0.range) }, ["Three"],
                       "the missing paragraph is the one tertiary run")
        XCTAssertEqual(inks.filter(\.isSource).map { slice(surface, $0.range) }, ["One", "Two"],
                       "each source line is a secondary run, and nothing else is")
    }

    /// Off, the surface is byte-for-byte the one before there was a source
    /// under it: each paragraph's text, joined by a blank line.
    func test_sourceUnderOffIsTodaysSurface() {
        let entries = EditorHost.reviewBadgeEntries(from: derived(), showsSourceUnder: false)
        XCTAssertEqual(TranslationBadgeLayout.surface(entries: entries), "Jedan\n\nDva\n\nThree")
        XCTAssertEqual(TranslationBadgeLayout.surface(entries: entries),
                       entries.map(\.text).joined(separator: "\n\n"))
        XCTAssertTrue(TranslationBadgeLayout.ranges(entries: entries).allSatisfy { $0.sourceRange == nil })
    }

    /// A stale translation keeps its source under it, so the writer reads
    /// what the source says NOW beside the out-of-date line (and the amber
    /// dot marks the paragraph).
    func test_aStaleParagraphKeepsTheCurrentSourceUnderIt() {
        let entries = EditorHost.reviewBadgeEntries(from: derived(stale: true), showsSourceUnder: true)
        XCTAssertEqual(entries[1].status, .stale)
        XCTAssertEqual(entries[1].source, "Two")
        XCTAssertEqual(ReadingLanguageLine.countsLine(ReadingLanguageLine.counts(entries)),
                       "1 paragraph out of date \u{00b7} 1 not translated yet")
    }

    /// Nothing is repeated that adds nothing: a verbatim paragraph, a figure
    /// line (a second picture) and a table (a second grid).
    func test_aVerbatimFigureOrTableParagraphIsNotRepeated() {
        let paragraphs = ["v": "Lorem ipsum", "f": "![A map](figures/map.png)",
                          "t": "| a | b |\n|---|---|\n| 1 | 2 |"]
        let records = [
            TranslationRecord(paragraphId: "v", language: "sr", text: "Lorem ipsum",
                              sourceHash: TranslationHash.hash("Lorem ipsum")),
            TranslationRecord(paragraphId: "f", language: "sr", text: "![Mapa](figures/map.png)",
                              sourceHash: TranslationHash.hash(paragraphs["f"]!)),
            TranslationRecord(paragraphId: "t", language: "sr", text: "| a | b |\n|---|---|\n| jedan | dva |",
                              sourceHash: TranslationHash.hash(paragraphs["t"]!)),
        ]
        let derived = TranslationDeriver.derive(records: records, sequence: ["v", "f", "t"],
                                                paragraphs: paragraphs, language: "sr").entries
        let entries = EditorHost.reviewBadgeEntries(from: derived, showsSourceUnder: true)
        XCTAssertEqual(entries.map(\.source), [nil, nil, nil])
    }

    /// **A screenplay keeps its structure**: the translation carries the
    /// source's elements (the source element wins, v0.32.1), and its source
    /// sits a blank line under it — so neither half reads as the other's
    /// dialogue.
    func test_aScreenplayKeepsItsStructureAndItsSourceUnderABlankLine() {
        let source = "EXT. TERRACE - DAY"
        let records = [TranslationRecord(paragraphId: "s", language: "sr", text: "ЕКСТ. ТЕРАСА - ДАН",
                                         sourceHash: TranslationHash.hash(source))]
        let derived = TranslationDeriver.derive(records: records, sequence: ["s"],
                                                paragraphs: ["s": source], language: "sr").entries
        let entries = EditorHost.reviewBadgeEntries(from: derived, showsSourceUnder: true,
                                                    isScreenplay: true)
        XCTAssertEqual(entries[0].text, ".ЕКСТ. ТЕРАСА - ДАН", "forced a heading, as Publish does")
        XCTAssertEqual(TranslationBadgeLayout.surface(entries: entries),
                       ".ЕКСТ. ТЕРАСА - ДАН\n\nEXT. TERRACE - DAY")
        let ranges = TranslationBadgeLayout.ranges(entries: entries)
        let surface = TranslationBadgeLayout.surface(entries: entries)
        XCTAssertEqual(slice(surface, ranges[0].sourceRange), source)
    }

    /// **The swap is one call of the one external-text site**, and the same
    /// surface again is none (tripwire 7; Review Focus 4).
    @MainActor
    func test_theSurfaceSwapsThroughTheOneExternalTextSite() {
        let harness = EditorIntegrationHarness(initialText: "One\n\nTwo\n\nThree")
        let coordinator = harness.coordinator
        let surface = TranslationBadgeLayout.surface(
            entries: EditorHost.reviewBadgeEntries(from: derived(), showsSourceUnder: true))
        let before = coordinator.applyExternalTextCallCount
        EditorSurface.reconcileTextBuffer(textView: harness.textView, coordinator: coordinator,
                                          translationLanguage: "sr", text: surface,
                                          undoCoherentApply: false)
        XCTAssertEqual(coordinator.applyExternalTextCallCount, before + 1)
        XCTAssertEqual(harness.textView.string, surface)
        XCTAssertTrue(coordinator.isReadingTranslation, "the membrane flipped with the swap")
        EditorSurface.reconcileTextBuffer(textView: harness.textView, coordinator: coordinator,
                                          translationLanguage: "sr", text: surface,
                                          undoCoherentApply: false)
        XCTAssertEqual(coordinator.applyExternalTextCallCount, before + 1, "an unchanged surface is no swap")
        XCTAssertFalse(coordinator.textView(harness.textView,
                                            shouldChangeTextIn: NSRange(location: 1, length: 0),
                                            replacementString: "x"),
                       "neither the translation nor a source line under it takes a keystroke")
        let sourceLine = (surface as NSString).range(of: "Two")
        XCTAssertFalse(coordinator.textView(harness.textView, shouldChangeTextIn: sourceLine,
                                            replacementString: "Deux"))
        EditorSurface.reconcileTextBuffer(textView: harness.textView, coordinator: coordinator,
                                          translationLanguage: nil, text: "One\n\nTwo\n\nThree",
                                          undoCoherentApply: false)
        XCTAssertEqual(coordinator.applyExternalTextCallCount, before + 2)
        XCTAssertFalse(coordinator.isReadingTranslation)
    }

    /// **A reading position, not a typing caret** (fix round (b)): over a
    /// translation the insertion point is drawn — the view is not editable,
    /// which would otherwise draw none — in the quieter secondary ink.
    func test_aReadingPositionIsDrawnInQuietInkOverATranslation() {
        XCTAssertEqual(MaughamTextView.caretColor(typingIsOff: true, editing: .systemRed),
                       .secondaryLabelColor)
        XCTAssertEqual(MaughamTextView.caretColor(typingIsOff: false, editing: .systemRed),
                       .systemRed)
        XCTAssertTrue(MaughamTextView.drawsReadingPosition(typingIsOff: true,
                                                           isFirstResponder: true, selectionIsEmpty: true))
        XCTAssertFalse(MaughamTextView.drawsReadingPosition(typingIsOff: false,
                                                            isFirstResponder: true, selectionIsEmpty: true))
        XCTAssertFalse(MaughamTextView.drawsReadingPosition(typingIsOff: true,
                                                            isFirstResponder: false, selectionIsEmpty: true))
    }

    // MARK: - Copy (fix round (a))

    /// **Copy takes the translation, never the grey lines** — current, stale
    /// and missing paragraphs alike; a table (no source drawn) whole; and a
    /// selection made inside one source line copies that source.
    func test_copyTakesTheTranslationNeverTheSourceLines() {
        let paragraphs = ["a": "One", "b": "Two", "c": "Three", "t": "| a | b |\n|---|---|\n| 1 | 2 |"]
        let records = [
            TranslationRecord(paragraphId: "a", language: "sr", text: "Jedan",
                              sourceHash: TranslationHash.hash("One")),
            TranslationRecord(paragraphId: "b", language: "sr", text: "Dva", sourceHash: "STALE"),
            TranslationRecord(paragraphId: "t", language: "sr", text: "| a | b |\n|---|---|\n| jedan | dva |",
                              sourceHash: TranslationHash.hash(paragraphs["t"]!)),
        ]
        let derived = TranslationDeriver.derive(records: records, sequence: ["a", "b", "c", "t"],
                                                paragraphs: paragraphs, language: "sr").entries
        let entries = EditorHost.reviewBadgeEntries(from: derived, showsSourceUnder: true)
        let surface = TranslationBadgeLayout.surface(entries: entries)
        let ranges = TranslationBadgeLayout.ranges(entries: entries)
        let all = NSRange(location: 0, length: (surface as NSString).length)
        XCTAssertEqual(TranslationBadgeLayout.copyable(surface, selection: all, ranges: ranges),
                       "Jedan\n\nDva\n\nThree\n\n| a | b |\n|---|---|\n| jedan | dva |",
                       "fresh, stale, missing (its source, once) and a table, without one grey line")
        let inSource = (surface as NSString).range(of: "Two")
        XCTAssertEqual(TranslationBadgeLayout.copyable(surface, selection: inSource, ranges: ranges), "Two",
                       "a selection wholly inside a grey line copies the source asked for")
        XCTAssertEqual(TranslationBadgeLayout.translationOnly(surface, ranges: ranges),
                       TranslationBadgeLayout.copyable(surface, selection: all, ranges: ranges),
                       "a reading window counts what copy would take")
    }

    // MARK: - Stale text (fix round (d))

    /// A stale translation is inked as stale — never as current text — and
    /// VoiceOver says "out of date" / "not translated yet" on those paragraphs.
    @MainActor
    func test_aStaleTranslationIsInkedAndSpokenAsOutOfDate() {
        let entries = EditorHost.reviewBadgeEntries(from: derived(stale: true), showsSourceUnder: true)
        let surface = TranslationBadgeLayout.surface(entries: entries)
        let ranges = TranslationBadgeLayout.ranges(entries: entries)
        let inks = TranslationBadgeLayout.inks(ranges, length: (surface as NSString).length)
        XCTAssertEqual(inks.filter { $0.kind == .stale }.map { slice(surface, $0.range) }, ["Dva"])
        XCTAssertNotEqual(EditorCoordinator.color(of: .stale), NSColor.labelColor)
        let spoken = TranslationBadgeOverlayView.accessibilityLabels(ranges.filter { $0.status != .fresh },
                                                                      text: surface)
        XCTAssertEqual(spoken.count, 2)
        XCTAssertTrue(spoken[0].hasPrefix("Out of date") && spoken[0].contains("Dva"), spoken[0])
        XCTAssertTrue(spoken[1].hasPrefix("Not translated yet") && spoken[1].contains("Three"), spoken[1])
        XCTAssertNil(TranslationBadgeLayout.accessibilityNote(.fresh))
    }

    // MARK: - The reader's place (fix round (c))

    @MainActor
    func test_thePlaceLandsTheSameDistanceInWithinTheParagraph() {
        let place = EditorCoordinator.ReadingPlace(paragraphId: "b", into: 5, length: 3, fromTop: 40)
        XCTAssertEqual(EditorCoordinator.landing(place, in: NSRange(location: 100, length: 20)),
                       NSRange(location: 105, length: 3))
        XCTAssertEqual(EditorCoordinator.landing(place, in: NSRange(location: 100, length: 6)),
                       NSRange(location: 105, length: 1), "the selection stays within the paragraph")
        XCTAssertEqual(EditorCoordinator.landing(place, in: NSRange(location: 100, length: 2)),
                       NSRange(location: 102, length: 0), "a shorter paragraph clamps to its end")
    }

    /// **Choosing a language keeps the paragraph** — the swap itself carries
    /// the caret from paragraph b of the source into b's translation and back.
    @MainActor
    func test_aSwapKeepsTheParagraphBothWays() {
        let harness = EditorIntegrationHarness(initialText: "One\n\nTwo\n\nThree")
        let coordinator = harness.coordinator
        let sourceRanges = ["a": NSRange(location: 0, length: 3), "b": NSRange(location: 5, length: 3),
                            "c": NSRange(location: 10, length: 5)]
        coordinator.paragraphLocator = { location in
            let hit = sourceRanges.first { NSLocationInRange(location, $0.value) || NSMaxRange($0.value) == location }
            return hit.map { ($0.key, location - $0.value.location) }
        }
        coordinator.paragraphRangeProvider = { sourceRanges[$0] }
        let control = EditorControl()
        coordinator.observeControl(control)
        let entries = EditorHost.reviewBadgeEntries(from: derived(), showsSourceUnder: true)
        control.translationLanguage = "sr"
        control.translationBadges = .init(entries: entries)
        harness.setCursor(to: 6)                                   // "T|wo"
        EditorSurface.reconcileTextBuffer(textView: harness.textView, coordinator: coordinator,
                                          translationLanguage: "sr",
                                          text: TranslationBadgeLayout.surface(entries: entries),
                                          undoCoherentApply: false)
        let dva = TranslationBadgeLayout.ranges(entries: entries)[1].range
        XCTAssertEqual(harness.textView.selectedRange(), NSRange(location: dva.location + 1, length: 0),
                       "into b's translation, one in")
        control.translationLanguage = nil
        control.translationBadges = .empty
        EditorSurface.reconcileTextBuffer(textView: harness.textView, coordinator: coordinator,
                                          translationLanguage: nil, text: "One\n\nTwo\n\nThree",
                                          undoCoherentApply: false)
        XCTAssertEqual(harness.textView.selectedRange(), NSRange(location: 6, length: 0),
                       "and back to the same place in b")
    }

    /// The line over the text: what it is, that it is read-only, what to do
    /// instead.
    func test_theLineSaysReadOnlyAndWhatToDoInstead() {
        XCTAssertTrue(ReadingLanguageLine.lead("sr").contains("read-only"))
        XCTAssertTrue(ReadingLanguageLine.instead("sr").contains("write in Source"))
        XCTAssertNil(ReadingLanguageLine.countsLine(.init(stale: 0, missing: 0)))
        XCTAssertEqual(ReadingLanguageLine.countsLine(.init(stale: 3, missing: 0)),
                       "3 paragraphs out of date")
    }
}
