import XCTest
import AppKit
import SwiftUI
import MaughamCore
@testable import Maugham

/// **The Book's Brief** (shell plan 3 Task 5): the book's intent, then every
/// standing decision under one filter by where it was made, then the three
/// long statements that pull up. Pure decisions, plus mounted measurements
/// only (tripwire 33: nothing here presses a control).
@MainActor
final class BriefBookTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        FontWarmup.ensure()
    }

    private var fixtures: [StatementMountFixture] = []

    override func tearDown() async throws {
        for fixture in fixtures { await fixture.closeAndTearDown() }
        fixtures.removeAll()
        try await super.tearDown()
    }

    private func fixture(_ name: String) async throws -> StatementMountFixture {
        let made = try await StatementMountFixture.novel(named: name)
        fixtures.append(made)
        return made
    }

    private static let day: TimeInterval = 86_400

    private func ruling(_ text: String, on day: Int?) -> Ruling {
        Ruling(id: "", text: text,
               ruledOn: day.map { Date(timeIntervalSince1970: 1_700_000_000 + Double($0) * Self.day) },
               provenance: "test")
    }

    @discardableResult
    private func write(_ kind: Statement.Kind, _ scope: Statement.Scope, essay: String,
                       _ rulings: [Ruling], in store: ProjectStore) async throws -> String {
        let statement = try await store.createStatement(kind: kind, scope: scope)
        let text = RulingsSection.render(essay: essay, rulings: rulings)
        try await store.mutateStatementText(of: statement, session: "brief-book-test") { _ in text }
        return try store.statementText(of: statement)
    }

    private let structure = [
        StructureItem(id: "doc-a", title: "Arrival", type: .document, path: "a.md"),
        StructureItem(id: "doc-b", title: "Quiet", type: .document, path: "b.md"),
        StructureItem(id: "doc-c", title: "Storm", type: .document, path: "c.md"),
    ]

    private func decisions() -> [BriefDecision] {
        [
            BriefDecision(ruling: ruling("es: tú, never usted", on: 9), origin: .edition(language: "es")),
            BriefDecision(ruling: ruling("c: rain all night", on: 8), origin: .piece(docId: "doc-c")),
            BriefDecision(ruling: ruling("I overwrite endings", on: 7), origin: .lessons),
            BriefDecision(ruling: ruling("book: the harbour stays shut", on: 6), origin: .book),
            BriefDecision(ruling: ruling("a: no flashbacks", on: 5), origin: .piece(docId: "doc-a")),
            BriefDecision(ruling: ruling("reads for pace", on: 4), origin: .firstReader),
            BriefDecision(ruling: ruling("a: Kelly never lies", on: 10), origin: .piece(docId: "doc-a")),
        ]
    }

    // MARK: - The order (mounted)

    /// Going for (the book intent's editor — no marks at Book scope), then
    /// Decided with every origin's decisions, then the three lines that pull
    /// up, then what Claude has read.
    func test_theBooksBriefIsItsIntentThenEveryStandingDecision() async throws {
        let f = try await fixture("BriefBook")
        let docId = f.documentItemId
        let pieceTitle = try XCTUnwrap(f.store.manifest.structure.first { $0.id == docId }?.title)
        try await write(.intent, .project, essay: "The book is about a harbour.",
                        [ruling("the harbour stays shut", on: 1)], in: f.store)
        try await write(.intent, .document(docId), essay: "Chapter one turns on a lie.",
                        [ruling("no flashbacks", on: 2)], in: f.store)
        try await write(.lessons, .project, essay: "",
                        [ruling("I overwrite endings", on: 3)], in: f.store)
        let bible = BibleStore(projectRoot: f.projectURL, device: DeviceSlug.make(from: "brief-mac"))
        bible.record([BibleFact(id: "01BOOK", subject: "Harbour", fact: "The harbour is shut.",
                                establishedAt: nil, excerpt: nil, docId: docId, recordedAt: Date())])

        let window = f.hostView(AnyView(
            BriefPane(store: f.store, documentStore: f.documentStore, scope: .book,
                      diagnostics: nil, bible: bible, world: nil, centreItem: nil,
                      onOpenInCentre: { _ in }, onPullUp: { _ in },
                      onShowStrain: { _ in }, onOpenBrief: { _ in })))
        await pumpUntil(deadline: 5) {
            f.shows("no flashbacks", in: window) && !f.allTextViews(in: window).isEmpty
        }

        let texts = try f.allStaticTexts(in: window)
        func position(_ needle: String) -> Int? { texts.firstIndex { $0.contains(needle) } }
        // Decided's groups in the filter's order: the book, its pieces, the
        // ledger.
        let order = [GoingForView.heading, BriefDecidedSection.heading, "the harbour stays shut",
                     "no flashbacks", "I overwrite endings", BriefBookView.lessonsTitle,
                     BriefBookView.firstReaderTitle, BriefBookView.visualLanguageTitle,
                     BriefPieceView.readingsTitle]
        let positions = order.map(position)
        XCTAssertFalse(positions.contains(nil),
                       "missing from the pane: \(zip(order, positions).filter { $1 == nil }.map(\.0)) in \(texts)")
        XCTAssertEqual(positions.compactMap { $0 }, positions.compactMap { $0 }.sorted(),
                       "Going for, Decided, the pull-up lines, then the readings: \(texts)")
        XCTAssertTrue(texts.contains { $0.contains(pieceTitle) && $0.contains("Ruled") },
                      "a piece's decision names its piece: \(texts)")
        let editors = f.allTextViews(in: window)
        XCTAssertEqual(editors.count, 1, "Going for is the book intent's editor; no marks at Book scope")
        XCTAssertTrue(editors.first?.string.contains("The book is about a harbour.") == true)
        XCTAssertNil(f.documentStore.document(forDocId: docId), "and no manuscript was loaded")
    }

    /// A screenplay's Book is its one script: its Brief is the script's.
    func test_aScreenplaysBookBriefIsTheScripts() {
        let script = [StructureItem(id: "script", title: "Script", type: .document, path: "s.fountain")]
        XCTAssertEqual(BriefScope.of(.project, structure: script, projectType: .screenplay),
                       .piece(docId: "script"))
        XCTAssertEqual(BriefScope.of(.project, structure: structure, projectType: .novel), .book)
    }

    // MARK: - The filter (pure)

    func test_theFilterOffersEachOriginThatHasADecision() {
        let groups = BriefBookView.groups(decisions(), structure: structure) { _ in [] }
        XCTAssertEqual(BriefBookView.filterItems(groups).map(\.title),
                       ["All", "The book", "Arrival", "Storm", "What I've Learned",
                        "First Reader", "Spanish edition"],
                       "All, the book, pieces in manuscript order (Quiet decided nothing), "
                       + "the ledger, the first reader, each edition")
        XCTAssertNil(BriefBookView.filterItems(groups).first?.origin, "All is no filter")
        XCTAssertEqual(groups.first { $0.origin == .piece(docId: "doc-a") }?.decisions.map(\.text),
                       ["a: Kelly never lies", "a: no flashbacks"], "newest first within an origin")

        XCTAssertEqual(BriefBookView.shown(groups, filter: nil).count, groups.count)
        XCTAssertEqual(BriefBookView.shown(groups, filter: .lessons).map(\.origin), [.lessons])
        XCTAssertEqual(BriefBookView.shown(groups, filter: .piece(docId: "doc-b")).count, groups.count,
                       "a remembered origin that no longer decides anything shows everything")

        XCTAssertTrue(BriefBookView.filterItems([]).isEmpty, "nothing decided: no filter, no heading")
        XCTAssertTrue(BriefBookView.groups([], structure: structure) { _ in [] }.isEmpty)
    }

    /// 400 decisions: each origin draws its newest few and folds the rest,
    /// with Task 4's constant — the groups are built once, in `.task`.
    func test_aBookOfFourHundredDecisionsFoldsEachOrigin() {
        let many = (0..<400).map { n in
            BriefDecision(ruling: ruling("decision \(n)", on: n),
                          origin: n % 2 == 0 ? .piece(docId: "doc-a") : .book)
        }
        var asked: [BriefDecision.Origin] = []
        let groups = BriefBookView.groups(many, structure: structure) { asked.append($0); return [] }
        XCTAssertEqual(asked, [.book, .piece(docId: "doc-a")], "each origin's file order is read once")
        for group in groups {
            let layout = BriefDecidedSection.layout(group.decisions)
            XCTAssertEqual(layout.showing.count, BriefDecisions.showing)
            XCTAssertEqual(layout.earlierTitle, "197 earlier")
        }
    }

    /// **One read per key, never per row or per filter** (tripwire 4): the
    /// groups and their file orders are built only in `BriefPane.read`, which
    /// runs only in the pane's `.task(id: readKey)`; the Book's view reads no
    /// statement and groups nothing itself — a filter change re-reads nothing.
    func test_theBooksDecisionsAreReadOncePerKey() throws {
        let book = SourceScan.codeLines(of: try GoingForTests.source("Maugham/Views/Brief/BriefBookView.swift"))
        let body = try XCTUnwrap(book.firstIndex { $0.contains("var body: some View") })
        let drawn = book[body...].joined(separator: "\n")
        for reader in ["groups(", "currentRows(", "statementText(", "BriefReader.read("] {
            XCTAssertFalse(drawn.contains(reader), "the Book's view calls \(reader) while drawing")
        }
        let pane = SourceScan.codeLines(of: try GoingForTests.source("Maugham/Views/Brief/BriefPane.swift"))
            .joined(separator: "\n")
        XCTAssertEqual(pane.components(separatedBy: "BriefBookView.groups(").count - 1, 1,
                       "grouped in one place")
        XCTAssertEqual(pane.components(separatedBy: "Self.read(scope:").count - 1, 1)
        XCTAssertTrue(pane.contains(".task(id: readKey) { contents = Self.read(scope: scope"),
                      "and that place runs once per key, in `.task`")
    }

    // MARK: - A decision's origin

    func test_aDecisionNamesWhereItWasMade() {
        XCTAssertEqual(BriefBookView.title(of: .book, structure: structure), "The book")
        XCTAssertEqual(BriefBookView.title(of: .piece(docId: "doc-c"), structure: structure), "Storm")
        XCTAssertEqual(BriefBookView.title(of: .lessons, structure: structure), "What I've Learned")
        XCTAssertEqual(BriefBookView.title(of: .firstReader, structure: structure), "First Reader")
        XCTAssertEqual(BriefBookView.title(of: .edition(language: "es"), structure: structure),
                       "Spanish edition")

        let dated = ruling("no flashbacks", on: 2)
        let caption = RulingsStratum.caption(for: dated, origin: "Arrival")
        XCTAssertEqual(caption, "Arrival · " + (RulingsStratum.caption(for: dated) ?? ""))
        XCTAssertEqual(RulingsStratum.caption(for: Ruling(id: "", text: "x", ruledOn: nil, provenance: nil),
                                              origin: "The book"), "The book")
        XCTAssertNil(RulingsStratum.caption(for: Ruling(id: "", text: "x", ruledOn: nil, provenance: nil),
                                            origin: nil), "every other mount names nothing")

        XCTAssertEqual(BriefBookView.opensBrief(.piece(docId: "doc-a")), .item("doc-a"),
                       "a piece's decision opens that piece's Brief")
        for origin in [BriefDecision.Origin.book, .lessons, .firstReader, .edition(language: "es")] {
            XCTAssertNil(BriefBookView.opensBrief(origin), "\(origin)")
        }
        // Each origin's row acts on its own statement.
        XCTAssertEqual(BriefDecision.Origin.piece(docId: "doc-a").statement.scope, .document("doc-a"))
        XCTAssertEqual(BriefDecision.Origin.edition(language: "es").statement.kind, .editionBrief("es"))
        XCTAssertEqual(BriefDecision.Origin.lessons.statement.kind, .lessons)
    }

    // MARK: - The lines that pull up

    func test_theThreeBookStatementsPullUp() {
        XCTAssertEqual(BriefBookView.pullUpLines.map(\.title),
                       ["What I've Learned", "First Reader", "Visual Language"])
        let expected: [PulledUp] = [.lessons, .firstReader, .visualLanguage]
        for (line, item) in zip(BriefBookView.pullUpLines, expected) {
            let pulled = BriefBookView.pulledUp(line.request, structure: structure)
            XCTAssertEqual(pulled, item, line.title)
            // The state the link sets: the item pulled up beside the Book,
            // and the column moved to it.
            let before = WindowSubject.book
            let after = ClickRule.pullUp(try! XCTUnwrap(pulled), current: before)
            XCTAssertEqual(after.beside, item)
            XCTAssertEqual(after.open, .project, "the centre does not move")
            XCTAssertEqual(RightColumnContent.positionAfterSubjectChange(
                .brief, from: before, to: after, previousFace: .brief,
                structure: structure, projectType: .novel), .pulledUp, line.title)
        }
    }

    func test_theVisualLanguageLineCarriesTheProposalDot() async throws {
        XCTAssertTrue(BriefPullUpLines.showsDot(.visualLanguage, visualLanguageProposed: true))
        XCTAssertFalse(BriefPullUpLines.showsDot(.visualLanguage, visualLanguageProposed: false))
        XCTAssertFalse(BriefPullUpLines.showsDot(.lessons, visualLanguageProposed: true),
                       "only Visual Language carries the dot")

        let f = try await fixture("BriefVisualDot")
        XCTAssertFalse(BriefPullUpLines.visualLanguageProposed(projectURL: f.projectURL))
        _ = try StatementProposalStore(projectURL: f.projectURL).stage(.init(
            kind: .visualLanguage, markdown: "Serif, generous leading.",
            rationale: nil, proposedAt: Date(), author: "Claude"))
        XCTAssertTrue(BriefPullUpLines.visualLanguageProposed(projectURL: f.projectURL),
                      "a staged proposal is what the dot reads")
        let source = try GoingForTests.source("Maugham/Views/Brief/BriefBookView.swift")
        XCTAssertTrue(source.contains(".onProjectEvent(.maughamStatementProposalsChanged"),
                      "the dot re-reads when a proposal arrives or goes")
    }
}
