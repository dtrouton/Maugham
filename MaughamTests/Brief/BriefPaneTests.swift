import XCTest
import AppKit
import SwiftUI
import MaughamCore
@testable import Maugham

/// **Brief for a piece and a Part** (shell plan 3 Task 4): the order it draws
/// in, what it offers under a posture, how Decided folds, a Part's gathering,
/// the quiet lines, and the one-host rule. Pure decisions, plus mounted
/// measurements only (tripwire 33: nothing here presses a control).
@MainActor
final class BriefPaneTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        FontWarmup.ensure()
    }

    private var fixtures: [StatementMountFixture] = []
    private var closers: [Document] = []

    override func tearDown() async throws {
        for document in closers { await document.close() }
        closers.removeAll()
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

    /// Writes `(kind, scope)`'s statement and returns its whole text.
    @discardableResult
    private func write(_ kind: Statement.Kind, _ scope: Statement.Scope, essay: String,
                       _ rulings: [Ruling], in store: ProjectStore) async throws -> String {
        let statement = try await store.createStatement(kind: kind, scope: scope)
        let text = RulingsSection.render(essay: essay, rulings: rulings)
        try await store.mutateStatementText(of: statement, session: "brief-pane-test") { _ in text }
        return try store.statementText(of: statement)
    }

    private func pane(_ f: StatementMountFixture, scope: BriefScope,
                      diagnostics: DiagnosticsStore? = nil, bible: BibleStore? = nil,
                      centreItem: CentreItem? = nil) -> BriefPane {
        BriefPane(store: f.store, documentStore: f.documentStore, scope: scope,
                  diagnostics: diagnostics, bible: bible, world: nil, centreItem: centreItem,
                  onOpenInCentre: { _ in }, onPullUp: { _ in },
                  onShowStrain: { _ in }, onOpenBrief: { _ in })
    }

    // MARK: - The order (mounted)

    func test_aPieceBriefDrawsLineGoingForDecidedThenTheQuietLines() async throws {
        let f = try await fixture("BriefOrder")
        let docId = f.documentItemId
        try await f.store.updateInspector(id: docId, synopsis: "Kelly lies to the harbourmaster.")
        try await write(.intent, .project, essay: "The book is about a harbour.",
                        [ruling("the harbour stays shut", on: 1)], in: f.store)
        let essay = "Kelly never lies.\n\nThe storm is the climax."
        let intent = try await write(.intent, .document(docId), essay: essay,
                                     [ruling("no flashbacks", on: 2)], in: f.store)
        // A check that read exactly this intent: Going for reads, with marks.
        let diagnostics = DiagnosticsStore(projectRoot: f.projectURL, device: DeviceSlug.make(from: "brief-mac"))
        diagnostics.replace(
            run: CompilerRun(id: "r", at: Date(), model: "m", lastOpId: nil, deltaSummary: "",
                             intentSnapshot: intent,
                             clauseStatuses: [.init(clauseQuote: "Kelly never lies.", status: "strains", refs: [])],
                             kind: .check),
            diagnostics: [], docId: docId)
        let bible = BibleStore(projectRoot: f.projectURL, device: DeviceSlug.make(from: "brief-mac"))
        bible.record([BibleFact(id: "01FACT", subject: "Kelly", fact: "Kelly is a nurse.",
                                establishedAt: nil, excerpt: nil, docId: docId, recordedAt: Date())])

        let window = f.hostView(AnyView(pane(f, scope: .piece(docId: docId),
                                             diagnostics: diagnostics, bible: bible)))
        await pumpUntil(deadline: 5) { f.shows("What Claude has read", in: window) }

        let texts = try f.allStaticTexts(in: window)
        func position(_ needle: String) -> Int? { texts.firstIndex { $0.contains(needle) } }
        let order = ["Kelly lies to the harbourmaster.", GoingForView.heading, "Kelly never lies.",
                     BriefDecidedSection.heading, "no flashbacks", BriefPieceView.fromTheBook,
                     BriefPieceView.readingsTitle + " (1)"]
        let positions = order.map(position)
        XCTAssertFalse(positions.contains(nil),
                       "missing from the pane: \(zip(order, positions).filter { $1 == nil }.map(\.0)) in \(texts)")
        XCTAssertEqual(positions.compactMap { $0 }, positions.compactMap { $0 }.sorted(),
                       "the fixed order is line, Going for, Decided, then the quiet lines: \(texts)")
        XCTAssertTrue(f.allTextViews(in: window).isEmpty,
                      "marks that apply read — no editor is mounted")
    }

    // MARK: - What is offered

    func test_theLineFieldHidesUnderARefusingPosture() {
        XCTAssertEqual(BriefPane.offers(posture: .author, mayWriteTheLine: true),
                       BriefOffers(editsLine: true, editsIntent: true, confirms: true))
        let refusing = Posture(.unrestricted, yieldingTo: "Sam")
        XCTAssertFalse(refusing.allows(.editStatement), "premise: the posture refuses statement edits")
        XCTAssertEqual(BriefPane.offers(posture: refusing, mayWriteTheLine: false),
                       BriefOffers(editsLine: false, editsIntent: false, confirms: false))
        XCTAssertEqual(GoingForView.mode(hasMarks: false, editingRequested: false, inTheCentre: false,
                                         hasIntent: true, mayEdit: false), .reading,
                       "the intent's editor is hidden, not locked")
    }

    /// The line is a manifest field: it asks the tree's door for the piece
    /// (`TreeStructureVerbs.mayRestructure`, what Rename asks), not the
    /// intent's posture. A posture that may edit the intent but not the
    /// piece's structure hides the line's editing and keeps the intent's.
    func test_theLineAsksThePiecesStructureDoorNotTheIntents() {
        let piece = StructureItem(id: "doc-a", title: "A", type: .document, path: "a.md")
        let refusing = Posture(.unrestricted, yieldingTo: "Sam")
        let intentPosture = Posture.author
        let mayWrite = TreeStructureVerbs.mayRestructure(piece, postureOf: { $0 == "doc-a" ? refusing : .author })
        XCTAssertFalse(mayWrite, "premise: the piece's structure is refused")
        XCTAssertEqual(BriefPane.offers(posture: intentPosture, mayWriteTheLine: mayWrite),
                       BriefOffers(editsLine: false, editsIntent: true, confirms: true))
        XCTAssertTrue(TreeStructureVerbs.mayRestructure(piece, postureOf: { _ in .author }))
    }

    func test_committingAnUnchangedLineWritesNothing() {
        XCTAssertFalse(BriefPieceView.lineNeedsCommitting(draft: "A line.", stored: "A line."))
        XCTAssertFalse(BriefPieceView.lineNeedsCommitting(draft: "  A line.\n", stored: "A line."))
        XCTAssertFalse(BriefPieceView.lineNeedsCommitting(draft: "", stored: nil))
        XCTAssertTrue(BriefPieceView.lineNeedsCommitting(draft: "A new line.", stored: "A line."))
        XCTAssertTrue(BriefPieceView.lineNeedsCommitting(draft: "", stored: "A line."), "clearing is a write")
        XCTAssertTrue(BriefPieceView.lineNeedsCommitting(draft: "First.", stored: nil))
        XCTAssertFalse(BriefPieceView.lineNeedsCommitting(draft: "A line.", stored: "A line.  "),
                       "an old line stored with trailing spaces is not rewritten on every blur")
    }

    /// Review Focus 2: the piece is not open, and its intent is editable here.
    func test_aClosedPiecesIntentIsEditable() async throws {
        let f = try await fixture("BriefClosedPiece")
        let docId = f.documentItemId
        try await write(.intent, .document(docId), essay: "Chapter one turns on a lie.", [], in: f.store)
        let statement = try XCTUnwrap(f.store.statement(kind: .intent, scope: .document(docId)))

        let window = f.hostView(AnyView(pane(f, scope: .piece(docId: docId))))
        await pumpUntil(deadline: 5) { f.store.openStatementDocument(id: statement.id) != nil }

        XCTAssertEqual(f.allTextViews(in: window).count, 1, "Going for mounted the intent's editor")
        XCTAssertNotNil(f.store.openStatementDocument(id: statement.id), "the host bound the statement")
        XCTAssertNil(f.documentStore.document(forDocId: docId), "and no manuscript was loaded for it")
        XCTAssertTrue(f.documentStore.allOpenDocuments().isEmpty)
    }

    // MARK: - One host per statement (mounted)

    /// Review Focus 3: the intent open in the centre's cover (stood in for
    /// by a host of its own, as Task 5 will mount it) leaves Brief a
    /// placeholder line and no second editor.
    func test_theIntentInTheCentreLeavesOneEditor() async throws {
        let f = try await fixture("BriefCentreCover")
        let docId = f.documentItemId
        try await write(.intent, .document(docId), essay: "Chapter one turns on a lie.", [], in: f.store)
        let centre = CentreItem.statement(kind: .intent, scope: .document(docId))

        let window = f.hostView(AnyView(HStack(spacing: 0) {
            StatementEditorHost(store: f.store, documentStore: f.documentStore,
                                kind: .intent, scope: .document(docId), posture: .author)
                .frame(width: 300)
            pane(f, scope: .piece(docId: docId), centreItem: centre)
                .frame(width: 300)
        }), width: 600)
        await pumpUntil(deadline: 5) { f.shows(GoingForView.inTheCentreLine, in: window) }
        await waitOut(0.4)

        XCTAssertTrue(f.shows(GoingForView.inTheCentreLine, in: window))
        XCTAssertEqual(f.allTextViews(in: window).count, 1,
                       "one StatementEditorHost binds the intent; Brief draws a placeholder")
    }

    func test_noEditorWhileAnotherHostHoldsTheStatement() async throws {
        let f = try await fixture("BriefHeldElsewhere")
        let docId = f.documentItemId
        try await write(.intent, .document(docId), essay: "Chapter one turns on a lie.", [], in: f.store)
        let statement = try XCTUnwrap(f.store.statement(kind: .intent, scope: .document(docId)))
        // Another host's live Document, registered as a host registers one.
        let other = try await Document.load(
            url: f.store.resolvedProjectPath(statement.path), actor: .author,
            session: "other-host", presenter: nil)
        closers.append(other)
        f.store.noteStatementDocumentOpened(other, id: statement.id)

        let window = f.hostView(AnyView(pane(f, scope: .piece(docId: docId))))
        await pumpUntil(deadline: 5) { f.shows("Chapter one turns on a lie.", in: window) }
        await waitOut(0.4)

        XCTAssertTrue(f.allTextViews(in: window).isEmpty,
                      "a statement another host holds reads here; a second editor is the defect")
        XCTAssertTrue(f.shows("Chapter one turns on a lie.", in: window), "the reading view shows the intent")
        f.store.forgetStatementDocument(id: statement.id)
    }

    // MARK: - Decided, a Part, the quiet lines

    func test_threeDecisionsShowTheRestFold() {
        XCTAssertEqual(BriefDecisions.showing, 3)
        let five = (1...5).map { ruling("r\($0)", on: 10 - $0) }
        let layout = BriefDecidedSection.layout(five)
        XCTAssertEqual(layout.showing.map(\.text), ["r1", "r2", "r3"])
        XCTAssertEqual(layout.folded.map(\.text), ["r4", "r5"])
        XCTAssertEqual(layout.earlierTitle, "2 earlier")
        XCTAssertNil(BriefDecidedSection.layout(Array(five.prefix(3))).earlierTitle, "nothing folds")
        XCTAssertTrue(BriefDecidedSection.layout([]).isEmpty, "no decisions: no heading at all")
    }

    func test_aPartGathersItsChaptersDecisions() {
        let structure = [StructureItem(id: "grp", title: "Part One", type: .group, children: [
            StructureItem(id: "doc-a", title: "Arrival", type: .document, path: "a.md"),
            StructureItem(id: "doc-b", title: "Quiet", type: .document, path: "b.md"),
            StructureItem(id: "doc-c", title: "Storm", type: .document, path: "c.md"),
        ])]
        let decisions = [
            BriefDecision(ruling: ruling("c: rain all night", on: 9), origin: .piece(docId: "doc-c")),
            BriefDecision(ruling: ruling("a: no flashbacks", on: 2), origin: .piece(docId: "doc-a")),
            BriefDecision(ruling: ruling("a: Kelly never lies", on: 7), origin: .piece(docId: "doc-a")),
        ]
        let sections = BriefPartView.sections(docIds: ["doc-a", "doc-b", "doc-c"],
                                              decisions: decisions, structure: structure)
        XCTAssertEqual(sections.map(\.title), ["Arrival", "Storm"], "manuscript order; a chapter with none is absent")
        XCTAssertEqual(sections.first?.decisions.map(\.text), ["a: Kelly never lies", "a: no flashbacks"],
                       "newest first within a chapter")
    }

    func test_theQuietLinesHideWhenEmpty() {
        func snapshot(essay: String?, book: [Ruling], readings: Int) -> BriefSnapshot {
            BriefSnapshot(scope: .piece(docId: "d"), line: nil, intentText: nil, intentEssay: nil,
                          decisions: [], bookIntentEssay: essay, bookDecisions: book,
                          unconfirmedReadings: readings, unreadable: [])
        }
        XCTAssertFalse(BriefPane.quietLines(snapshot(essay: nil, book: [], readings: 0)).fromTheBook)
        XCTAssertFalse(BriefPane.quietLines(snapshot(essay: "  \n", book: [], readings: 0)).fromTheBook)
        XCTAssertNil(BriefPane.quietLines(snapshot(essay: nil, book: [], readings: 0)).readings)
        XCTAssertTrue(BriefPane.quietLines(snapshot(essay: "The book.", book: [], readings: 0)).fromTheBook)
        XCTAssertTrue(BriefPane.quietLines(snapshot(essay: nil, book: [ruling("x", on: 1)], readings: 0)).fromTheBook)
        XCTAssertEqual(BriefPane.quietLines(snapshot(essay: nil, book: [], readings: 2)).readings, 2)
    }

    func test_bibleReadingsSayConfirm() throws {
        XCTAssertEqual(BibleStratum.confirmTitle, "Confirm")
        let source = try GoingForTests.source("Maugham/Views/BibleStratum.swift")
        XCTAssertFalse(source.contains("Button(\"Bless\")"), "the control says the design's word")
        XCTAssertTrue(source.contains("Button(BibleStratum.confirmTitle) { bless(fact) }"),
                      "the verb is unchanged")
    }

    func test_outsideAndElsewhereSayWhatBriefIsAbout() async throws {
        XCTAssertEqual(BriefPane.elsewhereLine,
                       "This piece belongs to another project. Its brief is that project's.")
        XCTAssertEqual(BriefPane.outsideLine,
                       "Brief holds what a piece, a Part, the Book or an edition is held to. Choose one in the binder.")
        let f = try await fixture("BriefOutside")
        let outside = f.hostView(AnyView(pane(f, scope: .outside)))
        await pumpUntil(deadline: 5) { f.shows("Choose one in the binder.", in: outside) }
        XCTAssertTrue(f.shows("Choose one in the binder.", in: outside))
        let elsewhere = f.hostView(AnyView(pane(f, scope: .elsewhere(docId: f.documentItemId))))
        await pumpUntil(deadline: 5) { f.shows("belongs to another project", in: elsewhere) }
        XCTAssertTrue(f.shows("belongs to another project", in: elsewhere))
    }

    // MARK: - The column (a measurement)

    /// Brief fits the right column from 240 to 480pt: a long line, a long
    /// essay with marks, folded decisions and both quiet lines; a Part whose
    /// chapter title is 200 characters.
    func test_briefFitsTheColumn() async throws {
        let f = try await fixture("BriefWidth")
        let docId = f.documentItemId
        let long = String(repeating: "harbour ", count: 30)
        let essay = "Kelly never lies. " + long
        let snapshot = BriefSnapshot(
            scope: .piece(docId: docId), line: "A line " + long, intentText: essay, intentEssay: essay,
            decisions: (1...5).map { BriefDecision(ruling: ruling("decision \($0) " + long, on: $0),
                                                   origin: .piece(docId: docId)) },
            bookIntentEssay: long, bookDecisions: [ruling("book " + long, on: 1)],
            unconfirmedReadings: 3, unreadable: [])
        let marks = [ClauseMark(kind: .strains, range: NSRange(location: 0, length: 17), clauseQuote: "Kelly never lies.")]
        let contents = BriefContents(snapshot: snapshot, marks: marks,
                                     fileOrder: [docId: snapshot.decisions.map(\.ruling)], isRead: true)
        let piece = BriefPieceView(store: f.store, documentStore: f.documentStore, docId: docId,
                                   contents: contents, bible: nil, world: nil, inTheCentre: false,
                                   onOpenInCentre: { _ in }, onShowStrain: { _ in })
            .padding(.horizontal, 12)

        let title = String(repeating: "A", count: 200)
        let row = try XCTUnwrap(f.store.manifest.structure.firstIndex { $0.id == docId })
        f.store.manifest.structure[row].title = title
        let part = BriefPartView(store: f.store, documentStore: f.documentStore, docIds: [docId],
                                 contents: contents, world: nil, onOpenBrief: { _ in })
            .padding(.horizontal, 12)

        for width in [CGFloat(UIState.detailColumnWidthRange.lowerBound),
                      CGFloat(UIState.detailColumnWidthRange.upperBound)] {
            for (name, view) in [("piece", AnyView(piece)), ("part", AnyView(part))] {
                let host = NSHostingController(rootView: view.environment(f.preferences))
                let measured = host.sizeThatFits(in: CGSize(width: width, height: 10_000)).width
                XCTAssertLessThanOrEqual(measured, width + 0.5,
                                         "a \(name)'s Brief wants \(measured)pt in a \(width)pt column")
            }
        }
    }
}
