import XCTest
import MaughamCore
@testable import Maugham

/// Report foundations plan 2, Task 4: the resolution pass over the AST of the
/// WHOLE book numbers figures, tables, headings and footnotes, resolves
/// cross-references and citations, builds References and the lists, and
/// reports every problem against its piece and paragraph.
final class PublishResolutionTests: XCTestCase {

    // MARK: - fixtures

    /// A book of pieces, each `(id, paragraphs)`; display text is the join, so
    /// the paragraphs reconcile and problems can name their `¶id`.
    private struct Book: ProjectASTBuilder.Source {
        let pieces: [(id: String, paragraphs: [(id: String, text: String)])]
        var context: PublishContext = .empty
        func orderedPieces() -> [ProjectASTBuilder.PieceRef] {
            pieces.map { piece in
                .init(pieceID: piece.id, title: "Title \(piece.id)", mode: .prose,
                      displayText: piece.paragraphs.map(\.text).joined(separator: "\n\n"),
                      paragraphs: piece.paragraphs)
            }
        }
        func publishContext() -> PublishContext { context }
    }

    private func context(numberSections: Bool = true, lists: Bool = true,
                         library: CitationLibrary = CitationLibrary(items: []),
                         profile: ProjectProfile? = .report,
                         projectURL: URL? = nil,
                         piecePaths: [String: String] = [:]) -> PublishContext {
        PublishContext(library: library, profile: profile,
                       switches: (numberSections: numberSections, listOfFigures: lists,
                                  listOfTables: lists),
                       projectURL: projectURL, piecePaths: piecePaths)
    }

    private func resolve(_ book: Book, bodyTag: String? = nil,
                         allowed: Set<String> = ["png"]) throws -> PublishResolution {
        try PublishResolution.forCompile(source: book, bodyTag: bodyTag, imageAllowed: allowed)
    }

    private func label(_ reference: String) -> ManuscriptLabel {
        ManuscriptLabel(reference: reference)!
    }

    private func source(_ key: String, _ author: String, _ year: Int?, title: String) -> ResearchItem {
        ResearchItem(id: "id-\(key)", title: title, type: .asset,
                     citation: CitationInfo(key: key, authors: [author], year: year))
    }

    // MARK: - numbering (R-P2-2)

    func test_figuresTablesAndHeadings_areNumberedAcrossThreePieces() throws {
        let book = Book(pieces: [
            ("a", [("a1b2", "# Intro {#sec:intro}"),
                   ("c3d4", "![One](x.png){#fig:one}"),
                   ("e5f6", "## Scope {#sec:scope}")]),
            ("b", [("g7h8", "### Deep"),
                   ("j9k0", "#### Deeper {#sec:deeper}"),
                   ("m2n3", "| a |\n|---|\n| 1 |\nTable: Sales {#tbl:sales}"),
                   ("p4q5", "![Two](y.png)")]),
            ("c", [("r6s7", "# Method"),
                   ("t8v9", "![Three](z.png){#fig:three}"),
                   ("w2x3", "See @fig:three, @tbl:sales, @sec:scope and @sec:deeper.")]),
        ], context: context())
        let r = try resolve(book)

        XCTAssertEqual(r.figureNumbers, ["a": [1: 1], "b": [3: 2], "c": [1: 3]])
        XCTAssertEqual(r.tableNumbers, ["b": [2: 1]])
        XCTAssertEqual(r.headingNumbers, ["a": [0: "1", 2: "1.1"], "b": [0: "1.1.1"], "c": [0: "2"]],
                       "level 4 is unnumbered; piece titles never are")
        XCTAssertEqual(r.targets[label("fig:three")],
                       .init(pieceID: "c", paragraphID: "t8v9", text: "Figure 3"))
        XCTAssertEqual(r.targets[label("tbl:sales")]?.text, "Table 1")
        XCTAssertEqual(r.targets[label("sec:scope")]?.text, "Section 1.1")
        XCTAssertEqual(r.targets[label("sec:deeper")]?.text, "Deeper",
                       "an unnumbered heading reads as its own text")
        XCTAssertEqual(r.problems, [])
    }

    /// Review focus 2: a preview of one chapter numbers Figure 7 as 7, and a
    /// reference to a figure in an excluded chapter still resolves.
    func test_aPreviewSubset_keepsBookNumbering_andResolvesIntoExcludedPieces() throws {
        let six = (0..<6).map { (id: "a\($0)b2", text: "![F\($0)](f\($0).png)") }
        let book = Book(pieces: [
            ("a", [("z9z9", "![Early](e.png){#fig:early}")] + six.dropLast()),
            ("b", [("c3d4", "![Seventh](s.png){#fig:seven}")]),
            ("c", [("e5f6", "As @fig:early and @fig:seven show.")]),
        ], context: context())
        let preview = FilteredASTSource(base: book, sectionIDs: ["b", "c"], editionExcludedSectionIDs: [])

        let r = try PublishResolution.forCompile(source: preview, bodyTag: nil, imageAllowed: ["png"])
        let subset = try ProjectASTBuilder.build(from: preview)

        XCTAssertEqual(subset.sections.map(\.pieceID), ["b", "c"])
        XCTAssertEqual(r.figureNumbers["b"], [0: 7])
        XCTAssertEqual(r.targets[label("fig:early")]?.text, "Figure 1")
        XCTAssertEqual(r.targets[label("fig:early")]?.pieceID, "a")
        XCTAssertEqual(r.problems, [])
    }

    // MARK: - R-S15: the edition's book

    /// A Report with a draft chapter the edition leaves out (`include: false`).
    private func editionBook() -> Book {
        let library = CitationLibrary(items: [
            source("kept", "Adams", 2020, title: "Kept"),
            source("draftonly", "Baker", 2021, title: "Draft only"),
        ])
        return Book(pieces: [
            ("a", [("a1b2", "# One"), ("c3d4", "![F1](f.png){#fig:one}"),
                   ("e5f6", "Cited [@kept] and noted[^n]."), ("g7h8", "[^n]: A note.")]),
            ("b", [("j9k0", "# Draft"), ("m2n3", "![Draft](d.png){#fig:draft}"),
                   ("p4q5", "Unknown [@todo], [@draftonly], and a note[^d]."), ("r6s7", "[^d]: Draft note.")]),
            ("c", [("t8v9", "# Three"), ("w2x3", "![F3](g.png){#fig:three}"),
                   ("y4z5", "As @fig:one and @fig:three show, a third[^t]."), ("a6b7", "[^t]: Third.")]),
        ], context: context(library: library))
    }

    /// The edition's filter resolves over the pieces it publishes: the draft's
    /// unknown key is no problem, and numbers, notes and References skip
    /// nothing a reader can see.
    func test_theEditionsBook_leavesTheExcludedDraftOutOfEverything() throws {
        let edition = IncludeFilteredASTSource(base: editionBook(), excludedSectionIDs: ["b"])
        XCTAssertTrue(edition.isWholeBook, "the edition is its own book")
        let r = try PublishResolution.forCompile(source: edition, bodyTag: nil, imageAllowed: ["png"])

        XCTAssertEqual(r.problems, [], "the draft's [@todo] blocks nothing")
        XCTAssertEqual(r.figureNumbers, ["a": [1: 1], "c": [1: 2]], "no gap where the draft's figure was")
        XCTAssertEqual(r.headingNumbers, ["a": [0: "1"], "c": [0: "2"]], "no missing Section 2")
        XCTAssertEqual(r.footnoteNumbers, ["a": ["n": 1], "c": ["t": 2]], "notes run on unbroken")
        XCTAssertEqual(r.targets[label("fig:three")]?.text, "Figure 2")
        XCTAssertNil(r.targets[label("fig:draft")], "the draft's label is not in the book")
        XCTAssertEqual(r.referenceKeys, ["kept"], "a source cited only in the draft is not listed")
        XCTAssertEqual(r.listOfFigures.map(\.number), [1, 2])
    }

    /// A reference from an included chapter into the excluded draft points
    /// at nothing the book contains: an unresolved problem, never "Figure 2".
    func test_aReferenceIntoTheExcludedDraft_isUnresolved() throws {
        var pieces = editionBook().pieces
        pieces[2].paragraphs[2] = ("y4z5", "See @fig:draft, a third[^t].")
        let edition = IncludeFilteredASTSource(
            base: Book(pieces: pieces, context: editionBook().context), excludedSectionIDs: ["b"])
        let r = try PublishResolution.forCompile(source: edition, bodyTag: nil, imageAllowed: ["png"])
        XCTAssertEqual(r.problems.map(\.kind), [.unresolvedCrossRef(label("fig:draft"))])
        XCTAssertEqual(r.problems.first?.paragraphID, "y4z5")
        XCTAssertTrue(r.problems[0].isError(profile: .report))
    }

    /// A preview of one included chapter numbers as the edition does: its
    /// figure is Figure 2, not the raw binder's 3, and the edition's
    /// References are the preview's.
    func test_aPreviewOfOneIncludedChapter_numbersAsTheEdition() throws {
        let preview = FilteredASTSource(base: editionBook(), sectionIDs: ["c"],
                                        editionExcludedSectionIDs: ["b"])
        XCTAssertFalse(preview.isWholeBook)
        let r = try PublishResolution.forCompile(source: preview, bodyTag: nil, imageAllowed: ["png"])
        XCTAssertEqual(try ProjectASTBuilder.build(from: preview).sections.map(\.pieceID), ["c"])
        XCTAssertEqual(r.figureNumbers["c"], [1: 2])
        XCTAssertEqual(r.headingNumbers["c"], [0: "2"])
        XCTAssertEqual(r.footnoteNumbers["c"], ["t": 2])
        XCTAssertEqual(r.referenceKeys, ["kept"])
        XCTAssertEqual(r.problems, [])
    }

    /// R-S7: numbering counts from the shallowest level the book uses, so a
    /// book that starts at `##` never prints a leading "0.".
    func test_headingNumbers_countFromTheShallowestLevelUsed() throws {
        let book = Book(pieces: [
            ("a", [("a1b2", "## Scope {#sec:scope}"),
                   ("c3d4", "### Detail {#sec:detail}"),
                   ("e5f6", "##### Too deep")]),
            ("b", [("g7h8", "## Method"),
                   ("j9k0", "See @sec:detail.")]),
        ], context: context())
        let r = try resolve(book)
        XCTAssertEqual(r.headingNumbers, ["a": [0: "1", 1: "1.1"], "b": [0: "2"]],
                       "three levels below the shallowest is unnumbered")
        XCTAssertEqual(r.targets[label("sec:detail")]?.text, "Section 1.1")
        XCTAssertEqual(r.targets[label("sec:scope")]?.text, "Section 1")
    }

    func test_numberSectionsOff_aSectionReferenceReadsAsTheHeadingsText() throws {
        let book = Book(pieces: [("a", [("a1b2", "## The *Long* View {#sec:view}"),
                                        ("c3d4", "See @sec:view.")])],
                        context: context(numberSections: false))
        let r = try resolve(book)
        XCTAssertEqual(r.headingNumbers, [:])
        XCTAssertEqual(r.targets[label("sec:view")]?.text, "The Long View")
    }

    func test_aDuplicateLabel_isOneProblem_andTheFirstWins() throws {
        let book = Book(pieces: [
            ("a", [("a1b2", "![One](x.png){#fig:x}")]),
            ("b", [("c3d4", "![Two](y.png){#fig:x}"), ("e5f6", "@fig:x")]),
        ], context: context())
        let r = try resolve(book)
        XCTAssertEqual(r.targets[label("fig:x")], .init(pieceID: "a", paragraphID: "a1b2", text: "Figure 1"))
        XCTAssertEqual(r.problems, [.init(kind: .duplicateLabel(label("fig:x")), pieceID: "b",
                                          paragraphID: "c3d4", bodyTag: nil)])
    }

    func test_aLabelOfTheWrongKind_isIgnoredAndReported() throws {
        let book = Book(pieces: [("a", [
            ("a1b2", "## Heading {#fig:h}"),
            ("c3d4", "| a |\n|---|\n| 1 |\nTable: Cap {#fig:t}"),
            ("e5f6", "See @fig:h."),
        ])], context: context())
        let r = try resolve(book)
        XCTAssertNil(r.targets[label("fig:h")])
        XCTAssertEqual(r.problems.map(\.kind), [.labelOnWrongElement(label("fig:h")),
                                                 .labelOnWrongElement(label("fig:t")),
                                                 .unresolvedCrossRef(label("fig:h"))])
        XCTAssertEqual(r.problems.map(\.paragraphID), ["a1b2", "c3d4", "e5f6"])
        XCTAssertEqual(r.tableNumbers, ["a": [1: 1]], "the table is still numbered")
    }

    /// R7a-1 (Review Focus 4): a table figure's line, labelled `tbl:` or
    /// unlabelled, numbers as a table; labelled, it is a valid `@tbl:` target,
    /// with no wrong-element problem. A pipe table, an unlabelled table
    /// figure, a labelled table figure and an image figure read Table 1,
    /// Table 2, Table 3, Figure 1 (the same document in `ReferenceIndexTests`).
    func test_aTableFigureLine_numbersAsATable() throws {
        let book = Book(pieces: [("a", [
            ("a1b2", "| a |\n|---|\n| 1 |\nTable: Sales {#tbl:sales}"),
            ("j9k8", "![Unlabelled](figures/plain.csv)"),
            ("c3d4", "![Programme cash flows](figures/cash.csv){#tbl:cash}"),
            ("e5f6", "![Sites](figures/sites.png){#fig:sites}"),
            ("g7h8", "See @tbl:cash."),
        ])], context: context())
        let r = try resolve(book)
        XCTAssertEqual(r.tableNumbers, ["a": [0: 1, 1: 2, 2: 3]])
        XCTAssertEqual(r.figureNumbers, ["a": [3: 1]])
        XCTAssertEqual(r.targets[label("tbl:cash")],
                       .init(pieceID: "a", paragraphID: "c3d4", text: "Table 3"))
        XCTAssertEqual(r.targets[label("fig:sites")]?.text, "Figure 1")
        XCTAssertEqual(r.listOfTables.map(\.number), [1, 2, 3])
        XCTAssertEqual(r.problems, [])
    }

    /// The controls: an image labelled `tbl:` is still on the wrong element,
    /// and a table figure labelled `fig:` is still a figure (plan 7b diagnoses
    /// both kind mismatches).
    func test_aKindMismatchedFigureLine_keepsTodaysNumbering() throws {
        let book = Book(pieces: [("a", [
            ("a1b2", "![Wrong](w.png){#tbl:wrong}"),
            ("c3d4", "![Grid](figures/grid.csv){#fig:grid}"),
        ])], context: context())
        let r = try resolve(book)
        XCTAssertEqual(r.figureNumbers, ["a": [0: 1, 1: 2]])
        XCTAssertEqual(r.tableNumbers, [:])
        XCTAssertEqual(r.targets[label("fig:grid")]?.text, "Figure 2")
        XCTAssertEqual(r.problems.map(\.kind), [.labelOnWrongElement(label("tbl:wrong"))])
    }

    func test_aMalformedLabel_onAHeadingOrATableCaption_isAWarning() throws {
        let book = Book(pieces: [("a", [
            ("a1b2", "## Heading {#eq:one}"),
            ("c3d4", "| a |\n|---|\n| 1 |\nTable: Cap {#tbl:bad name}"),
            ("e5f6", "Prose with {#fig:x y} in the middle is left alone."),
        ])], context: context())
        let r = try resolve(book)
        XCTAssertEqual(r.problems, [
            .init(kind: .malformedLabel("eq:one"), pieceID: "a", paragraphID: "a1b2", bodyTag: nil),
            .init(kind: .malformedLabel("tbl:bad name"), pieceID: "a", paragraphID: "c3d4", bodyTag: nil),
        ])
    }

    func test_anUnresolvedCrossRef_namesItsParagraph() throws {
        let book = Book(pieces: [("a", [("a1b2", "Intro."), ("c3d4", "See @fig:revenue.")])],
                        context: context())
        let r = try resolve(book)
        XCTAssertEqual(r.problems, [.init(kind: .unresolvedCrossRef(label("fig:revenue")),
                                          pieceID: "a", paragraphID: "c3d4", bodyTag: nil)])
        XCTAssertEqual(r.problems[0].message, "No figure is labelled fig:revenue.")
    }

    // MARK: - citations (R-P2-4, R-P2-5)

    func test_anUnknownKey_isAProblem_andHasNoCitationText() throws {
        let book = Book(pieces: [("a", [("a1b2", "Claim [@smith2026; @known].")])],
                        context: context(library: CitationLibrary(items: [
                            source("known", "Lee", 2020, title: "K")])))
        let r = try resolve(book)
        XCTAssertEqual(r.problems, [.init(kind: .unknownCitationKey("smith2026"), pieceID: "a",
                                          paragraphID: "a1b2", bodyTag: nil)])
        XCTAssertEqual(r.problems[0].message, "No research source has the citation key smith2026.")
        XCTAssertEqual(r.citationText, [:], "a citation with an unknown key renders literally")
        XCTAssertEqual(r.references.count, 1, "the known key is still cited")
    }

    func test_abDisambiguation_reachesCitationText_andReferencesListOnlyCitedSources() throws {
        let library = CitationLibrary(items: [
            source("s1", "Smith, Jane", 2026, title: "Alpha"),
            source("s2", "Smith, John", 2026, title: "Beta"),
            source("unused", "Zed", 1999, title: "Never cited"),
        ])
        let book = Book(pieces: [("a", [("a1b2", "First [@s2, p. 3]."),
                                        ("c3d4", "Both [@s1; @s2].")])],
                        context: context(library: library))
        let r = try resolve(book)
        let s2 = [CitationItem(key: "s2", locator: "p. 3")]
        let both = [CitationItem(key: "s1", locator: nil), CitationItem(key: "s2", locator: nil)]
        XCTAssertEqual(r.citationText[PublishResolution.citationKey(s2)], "(Smith 2026b, p. 3)")
        XCTAssertEqual(r.citationText[PublishResolution.citationKey(both)], "(Smith 2026a; Smith 2026b)")
        XCTAssertEqual(r.references.count, 2)
        XCTAssertEqual(r.referenceKeys, ["s1", "s2"], "the cited keys, in References order")
        XCTAssertEqual(r.references.first?.first?.text, "Smith, Jane.")
        XCTAssertEqual(r.references.map { $0.map(\.text).joined() },
                       ["Smith, Jane. 2026a. Alpha.", "Smith, John. 2026b. Beta."],
                       "each entry carries its in-text letter (I2)")
        XCTAssertEqual(r.problems, [])
    }

    func test_aRepeatedKeyOrFootnoteInOneParagraph_isOneProblem() throws {
        let book = Book(pieces: [("a", [
            ("a1b2", "Twice [@x; @x] and [@x, p. 2], gone[^g] gone[^g]."),
            ("c3d4", "Again [@x] and[^g]."),
        ])], context: context())
        let r = try resolve(book)
        XCTAssertEqual(r.problems.map(\.kind), [.unknownCitationKey("x"), .missingFootnoteDefinition("g"),
                                                 .unknownCitationKey("x"), .missingFootnoteDefinition("g")])
        XCTAssertEqual(r.problems.map(\.paragraphID), ["a1b2", "a1b2", "c3d4", "c3d4"],
                       "one per paragraph, so each paragraph is still named")
    }

    func test_citationKey_distinguishesLocatorsAndOrder() {
        let a = CitationItem(key: "a", locator: nil), b = CitationItem(key: "b", locator: nil)
        let keys = [[a], [a, b], [b, a], [CitationItem(key: "a", locator: "p. 1")],
                    [CitationItem(key: "a", locator: "p. 1; b")]]
        XCTAssertEqual(Set(keys.map(PublishResolution.citationKey)).count, keys.count)
    }

    func test_aBodyWithNoCitations_hasNoReferences() throws {
        let r = try resolve(Book(pieces: [("a", [("a1b2", "Plain.")])], context: context()))
        XCTAssertEqual(r.references.count, 0)
    }

    // MARK: - footnotes (R-P2-3)

    func test_footnotes_numberContinuouslyInFirstReferenceOrder_scopedPerPiece() throws {
        let book = Book(pieces: [
            ("a", [("a1b2", "One[^y] two[^x] again[^y]."), ("c3d4", "[^x]: X.\n[^y]: Y.")]),
            ("b", [("e5f6", "Three[^x]."), ("g7h8", "[^x]: Other X.")]),
        ], context: context())
        let r = try resolve(book)
        XCTAssertEqual(r.footnoteNumbers, ["a": ["y": 1, "x": 2], "b": ["x": 3]])
        XCTAssertEqual(r.problems, [])
    }

    func test_anUnusedAndAMissingFootnote_andADuplicateDefinition() throws {
        let book = Book(pieces: [("a", [
            ("a1b2", "Ref[^gone] and[^d]."),
            ("c3d4", "[^spare]: Never used.\n[^d]: First."),
            ("e5f6", "[^d]: Second."),
        ])], context: context())
        let r = try resolve(book)
        XCTAssertEqual(r.footnoteNumbers, ["a": ["d": 1]], "only referenced, defined notes count")
        XCTAssertEqual(Set(r.problems.map { "\($0.kind)@\($0.paragraphID ?? "-")" }), [
            "\(PublishProblem.Kind.missingFootnoteDefinition("gone"))@a1b2",
            "\(PublishProblem.Kind.unusedFootnoteDefinition("spare"))@c3d4",
            "\(PublishProblem.Kind.duplicateFootnoteDefinition("d"))@e5f6",
        ])
        XCTAssertEqual(r.problems.count, 3)
    }

    /// Review focus 5: a problem inside a footnote definition reveals the
    /// paragraph holding the definition.
    func test_aProblemInAFootnoteDefinition_namesTheDefinitionsParagraph() throws {
        let book = Book(pieces: [("a", [("a1b2", "Text[^n]."), ("c3d4", "[^n]: See @tbl:missing.")])],
                        context: context())
        let r = try resolve(book)
        XCTAssertEqual(r.problems, [.init(kind: .unresolvedCrossRef(label("tbl:missing")),
                                          pieceID: "a", paragraphID: "c3d4", bodyTag: nil)])
    }

    // MARK: - where problems point

    /// Review focus 5: a problem in a table cell names the table's paragraph.
    func test_aProblemInATableCell_namesTheTablesParagraph() throws {
        let book = Book(pieces: [("a", [
            ("a1b2", "Before."),
            ("c3d4", "| Source | Claim |\n|---|---|\n| [@nobody] | see @fig:none |"),
        ])], context: context())
        let r = try resolve(book)
        XCTAssertEqual(r.problems, [
            .init(kind: .unknownCitationKey("nobody"), pieceID: "a", paragraphID: "c3d4", bodyTag: nil),
            .init(kind: .unresolvedCrossRef(label("fig:none")), pieceID: "a", paragraphID: "c3d4", bodyTag: nil),
        ])
    }

    func test_captionsListItemsAndBlockquotes_areResolved() throws {
        let book = Book(pieces: [("a", [
            ("a1b2", "![See @fig:a](x.png)"),
            ("c3d4", "- item @fig:b"),
            ("e5f6", "> quoted @fig:c"),
        ])], context: context())
        let r = try resolve(book)
        XCTAssertEqual(r.problems.map(\.kind), ["fig:a", "fig:b", "fig:c"].map {
            .unresolvedCrossRef(label($0)) })
        XCTAssertEqual(r.problems.map(\.paragraphID), ["a1b2", "c3d4", "e5f6"])
    }

    func test_problemsReadInBookOrder() throws {
        let book = Book(pieces: [
            ("a", [("a1b2", "See @fig:none.")]),
            ("b", [("c3d4", "![One](x.png){#tbl:wrong}")]),
        ], context: context())
        XCTAssertEqual(try resolve(book).problems.map(\.pieceID), ["a", "b"],
                       "a later piece's label problem never jumps ahead of an earlier piece's reference")
    }

    func test_aBodyTag_prefixesEveryMessage() throws {
        let book = Book(pieces: [("a", [("a1b2", "@sec:gone")])], context: context())
        let r = try resolve(book, bodyTag: "sr")
        XCTAssertEqual(r.problems.map(\.bodyTag), ["sr"])
        XCTAssertEqual(r.problems.first?.message, "[sr] No section is labelled sec:gone.")
    }

    // MARK: - lists (R-P2-6)

    func test_listsOfFiguresAndTables_followTheirSwitches() throws {
        let pieces: [(id: String, paragraphs: [(id: String, text: String)])] = [("a", [
            ("a1b2", "![Revenue](x.png){#fig:rev}"),
            ("c3d4", "| a |\n|---|\n| 1 |\nTable: Sales"),
        ])]
        let on = try resolve(Book(pieces: pieces, context: context(lists: true)))
        XCTAssertEqual(on.listOfFigures.map(\.number), [1])
        XCTAssertEqual(on.listOfFigures.first?.caption, [.text("Revenue")])
        XCTAssertEqual(on.listOfFigures.first?.target, .init(pieceID: "a", paragraphID: "a1b2", text: "Figure 1"))
        XCTAssertEqual(on.listOfTables.map(\.target.text), ["Table 1"])

        let off = try resolve(Book(pieces: pieces, context: context(lists: false)))
        XCTAssertTrue(off.listOfFigures.isEmpty)
        XCTAssertTrue(off.listOfTables.isEmpty)
    }

    // MARK: - images (R-P2-7)

    func test_figureImages_resolveInsideResearch_andAreReportedOtherwise() throws {
        let project = TestTemp.root.appendingPathComponent("Resolution-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: project.appendingPathComponent("research"),
                                                withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: project) }
        try Data([0x89]).write(to: project.appendingPathComponent("research/x.png"))
        try Data([0x89]).write(to: project.appendingPathComponent("research/x.bmp"))

        let book = Book(pieces: [("a", [
            ("a1b2", "![Good](../research/x.png)"),
            ("c3d4", "![Out](/etc/x.png)"),
            ("e5f6", "![Gone](../research/missing.png)"),
            ("g7h8", "![Bitmap](../research/x.bmp)"),
        ])], context: context(projectURL: project, piecePaths: ["a": "manuscript/ch1.md"]))
        let r = try resolve(book)

        XCTAssertEqual(r.figureFiles, ["a": [0: project.appendingPathComponent("research/x.png")
            .resolvingSymlinksInPath()]])
        XCTAssertEqual(r.problems.map(\.paragraphID), ["c3d4", "e5f6", "g7h8"])
        XCTAssertEqual(r.problems[0].kind, .figurePathNotLocal("/etc/x.png"))
        guard case .imageUnreadable = r.problems[1].kind, case .imageUnreadable = r.problems[2].kind else {
            return XCTFail("expected two unreadable images, got \(r.problems)")
        }
        XCTAssertEqual(r.problems[1].message,
                       "The figure image can't be used: there is no file at ../research/missing.png.")
        XCTAssertEqual(r.figureNumbers["a"], [0: 1, 1: 2, 2: 3, 3: 4], "every figure is numbered")
    }

    /// Final review I2: a table figure's line is no image, so in a real
    /// Report project its `.csv` on disk raises no problem (the image door
    /// would call it unreadable and refuse a versioned compile); only the
    /// lexical path rule judges it, so a path out of the project still is.
    func test_aTableFigureLine_inARealReport_isJudgedByThePathRuleAlone() throws {
        let project = TestTemp.root.appendingPathComponent("Resolution-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: project.appendingPathComponent("figures"),
                                                withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: project) }
        try "a,b\n1,2\n".write(to: project.appendingPathComponent("figures/cash.csv"),
                               atomically: true, encoding: .utf8)

        let book = Book(pieces: [("a", [
            ("a1b2", "![Cash](../figures/cash.csv){#tbl:cash}"),
            ("c3d4", "![Plain](../figures/cash.csv)"),
            ("e5f6", "![Out](/etc/cash.csv)"),
            ("g7h8", "See @tbl:cash."),
        ])], context: context(projectURL: project, piecePaths: ["a": "manuscript/ch1.md"]))
        let r = try resolve(book)

        XCTAssertEqual(r.tableNumbers["a"], [0: 1, 1: 2, 2: 3])
        XCTAssertEqual(r.figureFiles, [:], "a table figure stages no image")
        XCTAssertEqual(r.problems.map(\.kind), [.figurePathNotLocal("/etc/cash.csv")])
        XCTAssertEqual(r.problems.map(\.paragraphID), ["e5f6"])
    }

    func test_withNoProjectContext_figureImagesAreNotChecked() throws {
        let r = try resolve(Book(pieces: [("a", [("a1b2", "![X](/etc/x.png)")])], context: context()))
        XCTAssertEqual(r.problems, [])
        XCTAssertEqual(r.figureFiles, [:])
    }

    // MARK: - severity (R-P2-1)

    /// COMPILE-TIME GUARD: no `default:`, so a new `Kind` fails to compile
    /// here until its expected severity is written down — and then it belongs
    /// in `everyKind` below too.
    private func expectedErrorInAReport(_ kind: PublishProblem.Kind) -> Bool {
        switch kind {
        case .unresolvedCrossRef: return true
        case .unknownCitationKey: return true
        case .duplicateLabel: return true
        case .missingFootnoteDefinition: return true
        case .figurePathNotLocal: return true
        case .imageUnreadable: return true
        case .unusedFootnoteDefinition: return false
        case .duplicateFootnoteDefinition: return false
        case .labelOnWrongElement: return false
        case .malformedLabel: return false
        case .figureNotFound(let path): return !ManuscriptLabel.Kind.isTableFigurePath(path)
        case .figureAmbiguous: return false
        case .tableFigureLabelledFig: return true
        case .figureLineSharesParagraph: return false
        }
    }

    private var everyKind: [PublishProblem.Kind] {
        [.unresolvedCrossRef(label("fig:x")), .unknownCitationKey("k"), .duplicateLabel(label("tbl:x")),
         .missingFootnoteDefinition("1"), .duplicateFootnoteDefinition("1"),
         .unusedFootnoteDefinition("1"), .labelOnWrongElement(label("sec:x")),
         .malformedLabel("eq:1"), .figurePathNotLocal("/x.png"), .imageUnreadable("no file"),
         .figureNotFound("figures/x.csv"), .figureNotFound("figures/x.png"),
         .figureAmbiguous("figures/x.csv"),
         .tableFigureLabelledFig(label("fig:x")),
         .figureLineSharesParagraph("figures/x.csv")]
    }

    func test_severity_everyKindInEveryProfile() {
        for kind in everyKind {
            let problem = PublishProblem(kind: kind, pieceID: "a", paragraphID: nil, bodyTag: nil)
            XCTAssertEqual(problem.isError(profile: .report), expectedErrorInAReport(kind), "\(kind)")
            XCTAssertFalse(problem.isError(profile: nil), "nothing blocks outside a Report: \(kind)")
            XCTAssertFalse(problem.isError(profile: .unknown("novel")), "\(kind)")
            XCTAssertFalse(problem.message.isEmpty)
        }
    }
}
