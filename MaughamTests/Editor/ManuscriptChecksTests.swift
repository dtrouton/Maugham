// MaughamTests/Editor/ManuscriptChecksTests.swift
import XCTest
import AppKit
import MaughamCore
@testable import Maugham

/// The editor's per-document reference checks (plan 3b Task 6, R-3b-4) and
/// the label text and placement maths (R-3b-1, R-3b-2). Pure: the tokens come
/// from the prose tokenizer the editor runs, the index is built by hand.
@MainActor
final class ManuscriptChecksTests: XCTestCase {

    // MARK: - Fixture

    private static let library: [ResearchItem] = [
        ResearchItem(id: "1", title: "Item 1", type: .asset, kind: .link, url: "https://example.com/1",
                     citation: CitationInfo(key: "smith2026", authors: ["Smith, Jane"],
                                            sourceTitle: "Markets", year: 2026)),
    ]

    /// An index of one source and one figure, `fig:chart` ("Figure 1"),
    /// defined in another piece; version 1, as a built host's is.
    nonisolated private static func index() -> ReferenceIndex {
        ReferenceIndex.build(
            pieces: [("other", ReferenceIndex.PieceSummary(text: "![Chart](c.png){#fig:chart}"))],
            research: library, words: .english).versioned(1)
    }

    private func problems(_ text: String, index: ReferenceIndex? = ManuscriptChecksTests.index(),
                          elsewhere: Set<ManuscriptLabel> = [])
        -> [(text: String, kind: PublishProblem.Kind)] {
        let ns = text as NSString
        return ManuscriptChecks.problems(in: ProseMode().tokenize(text), text: ns, index: index,
                                         labelsElsewhere: elsewhere)
            .map { (ns.substring(with: $0.range), $0.kind) }
    }

    private func label(_ reference: String) -> ManuscriptLabel { ManuscriptLabel(reference: reference)! }

    // MARK: - Citations and cross-references

    func test_anUnknownKeyIsMarkedOnItsOwnItem() {
        let found = problems("As shown [@smith2026; @ghost, p. 3] here.")
        XCTAssertEqual(found.map(\.text), ["@ghost"])
        XCTAssertEqual(found.map(\.kind), [.unknownCitationKey("ghost")])
    }

    func test_aKnownKeyIsNotMarked() {
        XCTAssertTrue(problems("As shown [@smith2026, p. 3].").isEmpty)
    }

    func test_anUnresolvedCrossReferenceIsMarked() {
        let found = problems("See @fig:missing and @fig:chart.")
        XCTAssertEqual(found.map(\.text), ["@fig:missing"])
        XCTAssertEqual(found.map(\.kind), [.unresolvedCrossRef(label("fig:missing"))])
    }

    func test_aMixedBracketMarksTheItemAtFault() {
        let found = problems("See [@smith2026; @tbl:none] now.")
        XCTAssertEqual(found.map(\.text), ["@tbl:none"])
    }

    /// A label this document's live text defines on its own kind of element
    /// resolves before the index catches up (fix round 1, M3); a label on the
    /// wrong kind of element does not.
    func test_aLabelDefinedHereResolvesBeforeTheIndexCatchesUp() {
        XCTAssertTrue(problems("![New](n.png){#fig:new}\n\nSee @fig:new.").isEmpty)
        XCTAssertEqual(problems("# Heading {#fig:new}\n\nSee @fig:new.").map(\.kind),
                       [.unresolvedCrossRef(label("fig:new"))], "the control: a heading is no figure")
    }

    /// The checks read each block through the reader they're handed (the
    /// coordinator's cache, fix round 1 M5), once per block.
    func test_theChecksReadBlocksThroughTheGivenReader() {
        let text = "See [@ghost].\n\nAnd @fig:chart.\n\nPlain."
        var reads: [String] = []
        _ = ManuscriptChecks.analyse(tokens: ProseMode().tokenize(text), text: text as NSString,
                                     index: Self.index(), labelsElsewhere: [],
                                     blockGroups: { reads.append($0); return ManuscriptChecks.groups(inBlockText: $0) })
        XCTAssertEqual(reads.count, 2, "two blocks hold markers; the plain one is never read")
    }

    /// The index not built yet: no key or reference is called unknown.
    func test_withNoIndexTheIndexChecksWait() {
        XCTAssertTrue(problems("See [@ghost] and @fig:missing.", index: nil).isEmpty)
    }

    // MARK: - Labels

    func test_aLabelDefinedTwiceHereMarksTheSecond() {
        let text = "# One {#sec:intro}\n\nProse.\n\n# Two {#sec:intro}\n"
        let found = problems(text)
        XCTAssertEqual(found.map(\.kind), [.duplicateLabel(label("sec:intro"))])
        let ns = text as NSString
        let second = ns.range(of: "{#sec:intro}", options: .backwards)
        let ranges = ManuscriptChecks.problems(in: ProseMode().tokenize(text), text: ns,
                                               index: Self.index(), labelsElsewhere: []).map(\.range)
        XCTAssertEqual(ranges, [second], "the first one counts")
    }

    func test_aLabelDefinedHereAndElsewhereIsMarked() {
        let text = "![Chart](c.png){#fig:chart}\n"
        XCTAssertEqual(problems(text, elsewhere: [label("fig:chart")]).map(\.kind),
                       [.duplicateLabel(label("fig:chart"))])
        XCTAssertTrue(problems(text, elsewhere: []).isEmpty, "the control: defined only here")
        XCTAssertTrue(problems(text, index: nil, elsewhere: [label("fig:chart")]).isEmpty,
                      "elsewhere is the index's to say")
    }

    // MARK: - Footnotes

    func test_aFootnoteWithNoDefinitionIsMissing() {
        let found = problems("A claim.[^1]\n")
        XCTAssertEqual(found.map(\.text), ["[^1]"])
        XCTAssertEqual(found.map(\.kind), [.missingFootnoteDefinition("1")])
    }

    func test_aSecondDefinitionIsADuplicate() {
        let found = problems("A claim.[^n]\n\n[^n]: First.\n\n[^n]: Second.\n")
        XCTAssertEqual(found.map(\.kind), [.duplicateFootnoteDefinition("n")])
        XCTAssertEqual(found.map(\.text), ["[^n]:"])
    }

    func test_aDefinitionNothingUsesIsUnused_andWhatItReferencesIsNeverRead() {
        let text = "A claim.[^a]\n\n[^a]: Used.\n\n[^b]: Unused, cites [^c].\n\n[^c]: Deeper.\n"
        XCTAssertEqual(problems(text).map(\.kind),
                       [.unusedFootnoteDefinition("b"), .unusedFootnoteDefinition("c")])
    }

    /// A reference inside a used definition is read, to a fixed point, and
    /// numbered after the text's own references.
    func test_aReferenceInsideAUsedDefinitionCounts() {
        let text = "Late[^z], early[^a], again[^z].\n\n[^a]: See [^b].\n\n[^b]: Deep.\n\n[^z]: Zed.\n"
        let ns = text as NSString
        let analysis = ManuscriptChecks.analyse(tokens: ProseMode().tokenize(text), text: ns,
                                                index: Self.index(), labelsElsewhere: [])
        XCTAssertEqual(analysis.problems, [])
        XCTAssertEqual(analysis.footnoteNumbers, ["z": 1, "a": 2, "b": 3],
                       "first-reference order in this document")
    }

    // MARK: - What is never marked

    func test_negatives_anEmailAHandleACodeSpanAndAnEscape() {
        XCTAssertTrue(problems("Write to jo@fig.com or @sarah.").isEmpty)
        XCTAssertTrue(problems("Type `[@ghost]` and `@fig:missing` literally.").isEmpty)
        XCTAssertTrue(problems("Not a marker: \\[@ghost].").isEmpty)
    }

    // MARK: - Severity and words

    func test_severityFollowsTheProfile() {
        let unknown = PublishProblem.Kind.unknownCitationKey("ghost")
        let unused = PublishProblem.Kind.unusedFootnoteDefinition("b")
        XCTAssertEqual(EditorCoordinator.problemColor(unknown, profile: .report), .systemRed)
        XCTAssertEqual(EditorCoordinator.problemColor(unknown, profile: nil), .systemOrange,
                       "a novel's [@sarah] is never an error")
        XCTAssertEqual(EditorCoordinator.problemColor(unknown, profile: .unknown("zine")), .systemOrange)
        XCTAssertEqual(EditorCoordinator.problemColor(unused, profile: .report), .systemOrange)
    }

    /// The editor's sentence is the publishing desk's.
    func test_theWordsArePublishings() {
        let kind = PublishProblem.Kind.unknownCitationKey("ghost")
        let desk = PublishProblem(kind: kind, pieceID: "p", paragraphID: nil, bodyTag: nil)
        XCTAssertEqual(PublishProblem.sentence(for: kind), desk.message)
        XCTAssertEqual(PublishProblem.isError(kind, profile: .report), desk.isError(profile: .report))
    }

    // MARK: - Label text (R-3b-2)

    func test_labelText_citationCrossReferenceAndFootnote() {
        let index = Self.index()
        func text(_ source: String) -> String? {
            let groups = ManuscriptChecks.groups(in: ProseMode().tokenize(source), text: source as NSString)
            XCTAssertEqual(groups.count, 1, source)
            return groups.first.flatMap {
                ManuscriptChecks.labelText(for: $0, index: index, footnoteNumbers: ["n": 4])
            }
        }
        XCTAssertEqual(text("As [@smith2026, p. 12] says."), "(Smith 2026, p. 12)")
        XCTAssertEqual(text("See @fig:chart."), "Figure 1")
        XCTAssertEqual(text("See [@fig:chart]."), "Figure 1")
        XCTAssertEqual(text("A claim.[^n]"), "4")
        XCTAssertEqual(text("See [@smith2026; @fig:chart]."), "(Smith 2026); Figure 1",
                       "a mixed bracket is one group")
        XCTAssertNil(text("As [@ghost] says."), "the underline speaks instead")
        XCTAssertNil(text("See @fig:missing."))
    }

    // MARK: - Placement maths (R-3b-1)

    func test_theLabelSizeIsAboutTwoThirdsOfTheBody_withAFloor() {
        XCTAssertEqual(ReferenceLabelLayout.labelPointSize(forBody: 17), 11)
        XCTAssertEqual(ReferenceLabelLayout.labelPointSize(forBody: 20), 13)
        XCTAssertEqual(ReferenceLabelLayout.labelPointSize(forBody: 10), 9, "never below the floor")
    }

    func test_theFitRule() {
        XCTAssertTrue(ReferenceLabelLayout.fits(inkHeight: 10, lineSpacing: 11.9))
        XCTAssertTrue(ReferenceLabelLayout.fits(inkHeight: 11.9, lineSpacing: 11.9))
        XCTAssertFalse(ReferenceLabelLayout.fits(inkHeight: 12, lineSpacing: 11.9))
        XCTAssertFalse(ReferenceLabelLayout.fits(inkHeight: 10, lineSpacing: 0), "no gap, no label")
        XCTAssertEqual(ReferenceLabelLayout.inkHeight(capHeight: 7.7, descender: -2.6), 11)
    }

    /// The default typography (17 pt at 1.7) leaves room beneath; a tight
    /// one (1.2) does not, so its labels wait for the caret or the pointer.
    func test_theFitRuleWithTheEditorsOwnFonts() {
        func fits(body: CGFloat, multiplier: CGFloat) -> Bool {
            let font = NSFont.systemFont(ofSize: ReferenceLabelLayout.labelPointSize(forBody: body))
            return ReferenceLabelLayout.fits(
                inkHeight: ReferenceLabelLayout.inkHeight(capHeight: font.capHeight, descender: font.descender),
                lineSpacing: body * (multiplier - 1))
        }
        XCTAssertTrue(fits(body: 17, multiplier: 1.7))
        XCTAssertFalse(fits(body: 17, multiplier: 1.2))
    }

    func test_beneath_rightAlignedOnTheMarkerAndCentredInTheGap() {
        let origin = ReferenceLabelLayout.beneathOrigin(
            markerMaxX: 300, gapTop: 100, lineSpacing: 12, labelWidth: 60,
            ascender: 10, capHeight: 7, inkHeight: 10, column: 20...500)
        XCTAssertEqual(origin.x, 240, "its right edge on the marker's")
        // Ink top at 100 + (12 - 10) / 2 = 101; baseline 108; drawn an ascender above.
        XCTAssertEqual(origin.y, 98)
    }

    func test_beneath_staysInsideTheColumn() {
        XCTAssertEqual(ReferenceLabelLayout.clampedX(rightEdge: 50, width: 60, column: 20...500), 20,
                       "a marker near the left edge: the label starts at the column")
        XCTAssertEqual(ReferenceLabelLayout.clampedX(rightEdge: 520, width: 60, column: 20...500), 440,
                       "a marker past the right edge: the label ends at the column")
        XCTAssertEqual(ReferenceLabelLayout.clampedX(rightEdge: 300, width: 600, column: 20...500), 20,
                       "wider than the column: the left edge wins")
    }

    func test_theTagSitsAboveTheLine() {
        let frame = ReferenceLabelLayout.tagFrame(markerMaxX: 300, lineTop: 200,
                                                  labelSize: CGSize(width: 50, height: 14),
                                                  column: 20...500)
        XCTAssertEqual(frame, CGRect(x: 242, y: 183, width: 58, height: 16))
        XCTAssertLessThan(frame.maxY, 200, "never over the line itself")
    }
}
