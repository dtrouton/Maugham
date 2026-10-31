import XCTest
@testable import Maugham
@testable import MaughamCore

/// **What a translator round on a piece is asked to label** (report plan 9e-2
/// Task 1, R6): the text cells of the tables the piece uses — missing or
/// stale, never fresh, never a number or a formula — filtered by the figure's
/// translation posture for the translator, so a pieces-author's translator
/// never sees a whole-book table's cells (Review Focus 3). A parked table is
/// absent; a table used twice is listed once.
@MainActor
final class TranslatorTableCellsTests: CellTranslationBookTestCase {

    // MARK: - The book

    /// A book of two chapters (`doc-a`, `doc-b`); `chapterA` is a.md's text.
    /// With `register`, another Mac roots the book and admits this one as an
    /// author of the whole book before the window opens.
    private func openBook(
        chapterA: String, chapterB: String = "Chapter B.\n", register: Bool = false
    ) async throws -> (DocumentStore, ProjectStore, root: DeviceIdentity?) {
        try chapterA.write(to: file("manuscript/a.md"), atomically: true, encoding: .utf8)
        try chapterB.write(to: file("manuscript/b.md"), atomically: true, encoding: .utf8)
        let manifest = ProjectManifest(
            type: .novel, title: "T", author: "A", created: Date(), modified: Date(),
            structure: [
                StructureItem(id: "doc-a", title: "Chapter A", type: .document, path: "manuscript/a.md"),
                StructureItem(id: "doc-b", title: "Chapter B", type: .document, path: "manuscript/b.md"),
            ],
            research: [])
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        try enc.encode(manifest).write(to: file(ProjectManifest.fileName))
        let root = register ? try makeForeignRoot() : nil
        let ds = try await DocumentStore.open(url: projectURL)
        for path in ["manuscript/a.md", "manuscript/b.md"] {
            let doc = try await Document.load(url: file(path), actor: .author, session: "boot", presenter: nil)
            await doc.close()
        }
        let store = try await ProjectStore.load(from: projectURL)
        store.documentStore = ds
        ds.projectStore = store
        await ds.postureSettled()
        return (ds, store, root)
    }

    /// Item | Amount / Rent | 100 / Total | =SUM-like text formula.
    private func ledger() -> FigureTable {
        var table = FigureTable(rows: 3, columns: 2)
        table.headerRows = 1
        func set(_ r: Int, _ c: Int, _ content: CellContent) {
            table.setCell(Cell(content: content), at: CellKey(row: table.rows[r], column: table.columns[c]))
        }
        set(0, 0, .value(.text("Item")))
        set(0, 1, .value(.text("Amount")))
        set(1, 0, .value(.text("Rent")))
        set(1, 1, .value(.number(100)))
        set(2, 0, .formula(Formula(.text("Total"))))
        set(2, 1, .value(.text("   ")))
        return table
    }

    private func key(_ table: FigureTable, _ r: Int, _ c: Int) -> CellKey {
        CellKey(row: table.rows[r], column: table.columns[c])
    }

    /// The round's table cells, gathered as the briefing gathers them.
    private func work(_ ds: DocumentStore, _ store: ProjectStore, docId: String = "doc-a",
                      language: String = "es") async throws -> [TableCellWork] {
        let state = try currentParagraphState(
            documentId: docId, store: store, documentStore: ds, projectURL: projectURL)
        return try await TranslatorOrchestrator.Environment.tableCellWork(
            docId: docId, language: language, state: (state.sequence, state.paragraphs),
            store: store, documentStore: ds, projectURL: projectURL)
    }

    // MARK: - Which cells

    /// **Missing and stale text cells are work; fresh, numbers, formulas and
    /// blanks are not.** Item is fresh (written against its source), Amount
    /// stale (its record hashed text it no longer has, so its last answer is
    /// handed over), Rent missing; 100 is a number, Total a formula whose
    /// result is text, and B3 blank — none of those three is ever briefed.
    func test_missingAndStaleTextCellsAreWork_freshNumbersAndFormulasAreNot() async throws {
        let (ds, store, _) = try await openBook(
            chapterA: "Opening.\n\n![Ledger](../figures/ledger.csv){#tbl:ledger}\n")
        let t = ledger()
        let record = try await store.createFigure(kind: .table, name: "ledger", piece: nil, table: t)
        XCTAssertEqual(record.path, "figures/ledger.csv", "premise: the line names this figure")
        await ds.awaitOpenFigureRenderForTesting()
        let live = try await table(store, record.id)

        try await write([.init(key: key(live, 0, 0), text: "Concepto")], figureId: record.id, table: live)
        try await TranslationStore.append(
            TranslationRecord(
                paragraphId: FigureCellTranslationKey.paragraphId(for: key(live, 0, 1)),
                language: "es", text: "Cantidad",
                sourceHash: TranslationHash.hash("Sum"), verbatim: false),
            forDocId: record.id,
            identity: try XCTUnwrap(Document.localIdentitiesForTesting).translator,
            identities: try XCTUnwrap(Document.localIdentitiesForTesting),
            state: try XCTUnwrap(Document.deviceStateForTesting), in: projectURL)

        let gathered = try await work(ds, store)
        XCTAssertEqual(gathered.count, 1)
        let only = try XCTUnwrap(gathered.first)
        XCTAssertEqual(only.figureId, record.id)
        XCTAssertEqual(only.name, "ledger")
        XCTAssertEqual(only.cells, [
            .init(key: key(live, 0, 1), address: "B1", sourceText: "Amount",
                  status: .stale, priorTranslation: "Cantidad"),
            .init(key: key(live, 1, 0), address: "A2", sourceText: "Rent",
                  status: .missing, priorTranslation: nil),
        ])

        // The disable experiment's control: in another language every text
        // cell is missing — and still only the three literals.
        let french = try await work(ds, store, language: "fr")
        XCTAssertEqual(french.first?.cells.map(\.address), ["A1", "B1", "A2"])
        XCTAssertEqual(french.first?.cells.map(\.status), [.missing, .missing, .missing])
    }

    /// **A table whose every text cell is fresh is no work** (R6: a whole-book
    /// table used in two pieces is done on the first round; the second finds
    /// it fresh), and a piece that uses no table gathers nothing.
    func test_aFullyTranslatedTableAndAPieceWithNoTableAreNoWork() async throws {
        let (ds, store, _) = try await openBook(
            chapterA: "Opening.\n\n![Ledger](../figures/ledger.csv){#tbl:ledger}\n")
        let record = try await store.createFigure(kind: .table, name: "ledger", piece: nil, table: ledger())
        await ds.awaitOpenFigureRenderForTesting()
        let live = try await table(store, record.id)
        try await write([.init(key: key(live, 0, 0), text: "Concepto"),
                         .init(key: key(live, 0, 1), text: "Cantidad"),
                         .init(key: key(live, 1, 0), verbatim: true)],
                        figureId: record.id, table: live)

        let doneHere = try await work(ds, store)
        XCTAssertEqual(doneHere, [])
        let elsewhere = try await work(ds, store, docId: "doc-b")
        XCTAssertEqual(elsewhere, [], "chapter B uses no table")
    }

    /// **A table used twice in the piece is listed once**, in first-use order
    /// beside another table.
    func test_aTableUsedTwiceIsListedOnceInFirstUseOrder() async throws {
        let (ds, store, _) = try await openBook(chapterA: """
            ![Plan](../figures/plan.csv){#tbl:plan}

            ![Ledger](../figures/ledger.csv){#tbl:ledger}

            ![Plan again](../figures/plan.csv){#tbl:plan}
            """)
        let ledgerRecord = try await store.createFigure(
            kind: .table, name: "ledger", piece: nil, table: ledger())
        let planRecord = try await store.createFigure(
            kind: .table, name: "plan", piece: nil, table: ledger())
        await ds.awaitOpenFigureRenderForTesting()

        let gathered = try await work(ds, store)
        XCTAssertEqual(gathered.map(\.figureId), [planRecord.id, ledgerRecord.id])
    }

    // MARK: - Parked

    /// **A parked table is absent**: sent to Research, its line no longer
    /// prints a table, so the round asks nothing of it.
    func test_aParkedTableIsAbsent() async throws {
        let (ds, store, _) = try await openBook(
            chapterA: "Opening.\n\n![Ledger](../figures/ledger.csv){#tbl:ledger}\n")
        let record = try await store.createFigure(kind: .table, name: "ledger", piece: nil, table: ledger())
        await ds.awaitOpenFigureRenderForTesting()
        let before = try await work(ds, store)
        XCTAssertEqual(before.map(\.figureId), [record.id], "premise: the table is work")

        _ = try await store.sendToResearch(figureId: record.id, scope: .document("doc-a"))
        await ds.awaitOpenFigureRenderForTesting()
        let parked = try await work(ds, store)
        XCTAssertEqual(parked, [])
    }

    // MARK: - Posture (Review Focus 3)

    /// **A pieces-author's translator on her chapter never sees a whole-book
    /// table's cells** (Review Focus 3): chapter A uses a whole-book table and
    /// one of A's own; narrowed to A, the round lists A's table alone — the
    /// whole-book one would be refused at the write door, so it is never
    /// briefed. Widened back to the whole book, both are work.
    ///
    /// The disable experiment: drop the posture filter in `tableCellWork` and
    /// the narrowed gather lists both tables.
    func test_aPiecesAuthorsTranslatorIsNotBriefedAWholeBookTablesCells() async throws {
        let (ds, store, root) = try await openBook(chapterA: """
            ![Books](../figures/books.csv){#tbl:books}

            ![Hers](../figures/hers.csv){#tbl:hers}
            """, register: true)
        let books = try await store.createFigure(kind: .table, name: "books", piece: nil, table: ledger())
        let hers = try await store.createFigure(kind: .table, name: "hers", piece: "doc-a", table: ledger())
        XCTAssertEqual(hers.path, "figures/hers.csv", "premise: the line names her table")
        await ds.awaitOpenFigureRenderForTesting()
        let whole = try await work(ds, store)
        XCTAssertEqual(whole.map(\.figureId), [books.id, hers.id], "premise: a book author's round")

        try await rootChangesMyPermit(to: .author(.pieces(["doc-a"])), root: try XCTUnwrap(root), ds)
        XCTAssertFalse(
            ds.translationPosture(forDocId: books.id, as: .translator).allows(.translate),
            "premise: the whole-book table's cells are not her translator's")
        let narrowed = try await work(ds, store)
        XCTAssertEqual(narrowed.map(\.figureId), [hers.id])
    }

    // MARK: - The briefing (Task 2)

    /// **The production briefing carries the round's table cells** and shows
    /// them to the model: `briefRound` on chapter A hands its tables to the
    /// briefing's `tableCells`, and the composed message lists each in the
    /// `[Table: name row:col]` form beside the paragraphs.
    func test_theProductionBriefingCarriesTheTablesCells() async throws {
        let (ds, store, _) = try await openBook(
            chapterA: "Opening.\n\n![Ledger](../figures/ledger.csv){#tbl:ledger}\n")
        let record = try await store.createFigure(kind: .table, name: "ledger", piece: nil, table: ledger())
        await ds.awaitOpenFigureRenderForTesting()
        let live = try await table(store, record.id)
        let environment = TranslatorOrchestrator.Environment.production(
            store: store, documentStore: ds, projectURL: projectURL,
            bible: BibleStore(projectRoot: projectURL, device: DeviceIdentity.author.slug),
            preferences: UserPreferences(
                defaults: UserDefaults(suiteName: "TranslatorTableCells-\(UUID().uuidString)")!),
            onRunEnded: { _ in })

        _ = try await environment.translatorIdentity("es")
        let round = try await environment.briefRound("doc-a", "es")
        let inputs = try XCTUnwrap(round).inputs
        XCTAssertEqual(inputs.tableCells.map(\.figureId), [record.id])
        XCTAssertEqual(inputs.tableCells.first?.cells.map(\.address), ["A1", "B1", "A2"])
        let message = TranslatorBriefing.compose(inputs: inputs)
        XCTAssertTrue(message.contains(
            "[Table: ledger \(FigureCellTranslationKey.paragraphId(for: key(live, 1, 0)))] (A2, missing"))
        XCTAssertTrue(message.contains("Table ledger (figure_id: \(record.id)):"))
    }

    // MARK: - Ingest (Task 3)

    /// Item | Q1 | Q2 / Rent | 100 | 110 / Food | 50 | 60 — a 3×3 table
    /// with header labels; its five text cells are the round's labels.
    private func quarters() -> FigureTable {
        var table = FigureTable(rows: 3, columns: 3)
        table.headerRows = 1
        func set(_ r: Int, _ c: Int, _ content: CellContent) {
            table.setCell(Cell(content: content), at: CellKey(row: table.rows[r], column: table.columns[c]))
        }
        set(0, 0, .value(.text("Item")))
        set(0, 1, .value(.text("Q1")))
        set(0, 2, .value(.text("Q2")))
        set(1, 0, .value(.text("Rent")))
        set(1, 1, .value(.number(100)))
        set(1, 2, .value(.number(110)))
        set(2, 0, .value(.text("Food")))
        set(2, 1, .value(.number(50)))
        set(2, 2, .value(.number(60)))
        return table
    }

    private static let spanish = [
        "Item": "Concepto", "Q1": "T1", "Q2": "T2", "Rent": "Alquiler", "Food": "Comida",
        "Amount": "Cantidad",
    ]

    /// The window's production environment over this book.
    private func production(_ ds: DocumentStore, _ store: ProjectStore)
        -> TranslatorOrchestrator.Environment {
        TranslatorOrchestrator.Environment.production(
            store: store, documentStore: ds, projectURL: projectURL,
            bible: BibleStore(projectRoot: projectURL, device: DeviceIdentity.author.slug),
            preferences: UserPreferences(
                defaults: UserDefaults(suiteName: "TranslatorTableCells-\(UUID().uuidString)")!),
            onRunEnded: { _ in })
    }

    /// A round on chapter A as production briefs it: the identity, then the
    /// briefing — what `TranslatorOrchestrator.begin` asks, in its order.
    private func brief(_ environment: TranslatorOrchestrator.Environment) async throws
        -> TranslatorOrchestrator.BriefedRound {
        _ = try await environment.translatorIdentity("es")
        let round = try await environment.briefRound("doc-a", "es")
        return try XCTUnwrap(round)
    }

    /// The translator's answer to `round`: every paragraph verbatim (the
    /// figure line must keep printing its table) and every briefed cell in
    /// Spanish; `cells` overrides which cells the answer carries.
    private func answer(_ round: TranslatorOrchestrator.BriefedRound,
                        cells: [TranslatorReport.Cell]? = nil,
                        cellsMalformed: Bool = false) -> TranslatorReport {
        TranslatorReport(
            entries: round.inputs.workList.map {
                .init(paragraphId: $0.paragraphId, text: nil, verbatim: true)
            },
            queries: [],
            cells: cells ?? round.inputs.tableCells.flatMap { table in
                table.cells.map {
                    TranslatorReport.Cell(figureId: table.figureId, key: $0.key,
                                          text: Self.spanish[$0.sourceText] ?? "ES", verbatim: nil)
                }
            },
            cellsMalformed: cellsMalformed)
    }

    /// Ingest `report` as the orchestrator hands it over: the round's own
    /// paragraph hashes and briefed cells.
    private func ingest(_ report: TranslatorReport, _ round: TranslatorOrchestrator.BriefedRound,
                        _ environment: TranslatorOrchestrator.Environment) async
        -> TranslatorOrchestrator.IngestOutcome {
        await environment.ingest(report, TranslatorOrchestrator.IngestContext(
            docId: "doc-a", language: "es", runId: "run-1",
            translatorName: "Elena Ruiz", translatorRoleId: "role-es",
            briefedSourceHashes: round.sourceHashes,
            briefedTableCells: round.inputs.tableCells))
    }

    /// The es body's layout of chapter A's table, through the one resolve
    /// door every compiler uses (`PublishProblemGate.resolve`).
    private func spanishLayout(_ store: ProjectStore) async throws -> FigureTableLayout {
        let source = ProjectStoreASTSource(projectStore: store, figures: await store.publishFigures())
        let bodies = try PublishProblemGate.resolve(bodies: [
            BodyPlan.Body(tag: nil, displayTag: "en", source: source, config: PublishConfig()),
            BodyPlan.Body(tag: "es", displayTag: "es", source: source.rebound(toLanguage: "es"),
                          config: PublishConfig()),
        ], imageAllowed: ["png"], macRegion: "US")
        return try XCTUnwrap(bodies[1].resolution.tableFigures["doc-a"]?.values.first,
                             "premise: the line lays out")
    }

    /// **Review Focus 1: a Spanish round on a chapter using a table labels
    /// it.** The round briefs the table's five text labels beside the
    /// paragraphs; ingest writes the paragraphs, then the cells through the
    /// one door as the translator. Afterwards the es body prints every label,
    /// and the gate's own reader finds nothing missing or stale — the table
    /// is satisfied. The disable experiment: skip `writeCells` and the es
    /// body prints the English labels while the gather still lists all five.
    func test_aSpanishRoundLabelsTheChaptersTable_andTheGateIsSatisfied() async throws {
        let (ds, store, _) = try await openBook(
            chapterA: "Opening.\n\n![Quarters](../figures/quarters.csv){#tbl:quarters}\n")
        let record = try await store.createFigure(kind: .table, name: "quarters", piece: nil, table: quarters())
        await ds.awaitOpenFigureRenderForTesting()
        let environment = production(ds, store)
        let round = try await brief(environment)
        XCTAssertEqual(round.inputs.tableCells.first?.cells.map(\.sourceText),
                       ["Item", "Q1", "Q2", "Rent", "Food"], "premise: the round briefs the labels")

        let outcome = await ingest(answer(round), round, environment)
        XCTAssertNil(outcome.rejection)
        XCTAssertEqual(outcome.entriesWritten, round.inputs.workList.count)
        XCTAssertEqual(outcome.cellsWritten, 5)
        XCTAssertEqual(outcome.cellRefusals, [])

        let after = try await work(ds, store)
        XCTAssertEqual(after, [], "the gate's reader finds the table fresh")
        let layout = try await spanishLayout(store)
        XCTAssertEqual(layout.header, ["Concepto", "T1", "T2"])
        XCTAssertEqual(layout.body.map(\.first), ["Alquiler", "Comida"])
        let records = try TranslationStore.loadMerged(forDocId: record.id, language: "es", in: projectURL)
        XCTAssertEqual(records.count, 5)
    }

    /// **Review Focus 2: a label edited mid-round lands stale, not fresh over
    /// the new text.** "Rent" is briefed; the writer changes it to "Rents"
    /// while the round is out; the answer's "Alquiler" is written hashed
    /// against "Rent" — the round's snapshot — so the next round finds it
    /// stale with its prior answer, and the es body prints the source. The
    /// disable experiment: drop `briefedSources` and the cell reads fresh.
    func test_aLabelEditedMidRoundLandsStale() async throws {
        let (ds, store, _) = try await openBook(
            chapterA: "Opening.\n\n![Quarters](../figures/quarters.csv){#tbl:quarters}\n")
        let record = try await store.createFigure(kind: .table, name: "quarters", piece: nil, table: quarters())
        await ds.awaitOpenFigureRenderForTesting()
        let live = try await table(store, record.id)
        let environment = production(ds, store)
        let round = try await brief(environment)

        let host = try await ds.openFigure(figureId: record.id)
        try await host.setCell(Cell(content: .value(.text("Rents"))), at: key(live, 1, 0))
        await ds.awaitOpenFigureRenderForTesting()
        await ds.closeFigure(figureId: record.id)

        let outcome = await ingest(answer(round), round, environment)
        XCTAssertEqual(outcome.cellsWritten, 5)
        XCTAssertEqual(outcome.cellRefusals, [])

        let next = try await work(ds, store)
        XCTAssertEqual(next.first?.cells, [
            .init(key: key(live, 1, 0), address: "A2", sourceText: "Rents",
                  status: .stale, priorTranslation: "Alquiler"),
        ])
        let layout = try await spanishLayout(store)
        XCTAssertEqual(layout.body.map(\.first), ["Rents", "Comida"], "the stale cell prints its source")
    }

    /// **A cell whose row was deleted mid-round is rejected loudly**: the
    /// table's batch is refused by the door (it validates against the
    /// CURRENT table), the refusal names the table in the round's report,
    /// and the paragraphs beside it still land.
    func test_aCellWhoseRowWasDeletedMidRoundIsRejectedInTheReport() async throws {
        let (ds, store, _) = try await openBook(
            chapterA: "Opening.\n\n![Quarters](../figures/quarters.csv){#tbl:quarters}\n")
        let record = try await store.createFigure(kind: .table, name: "quarters", piece: nil, table: quarters())
        await ds.awaitOpenFigureRenderForTesting()
        let live = try await table(store, record.id)
        let environment = production(ds, store)
        let round = try await brief(environment)

        let host = try await ds.openFigure(figureId: record.id)
        try await host.deleteRow(live.rows[2])
        await ds.awaitOpenFigureRenderForTesting()
        await ds.closeFigure(figureId: record.id)

        let outcome = await ingest(answer(round), round, environment)
        XCTAssertNil(outcome.rejection, "the paragraphs are not refused for a table's cell")
        XCTAssertEqual(outcome.entriesWritten, round.inputs.workList.count)
        XCTAssertEqual(outcome.cellsWritten, 0)
        XCTAssertEqual(outcome.cellRefusals.count, 1)
        let refusal = try XCTUnwrap(outcome.cellRefusals.first)
        XCTAssertEqual(refusal, TranslatorOrchestrator.Environment.tableSentence(
            "quarters", TranslatorOrchestrator.Environment.deletedMidRoundReason(["A3"])),
            "named by the address the round briefed: Food's row is gone")
        XCTAssertTrue(try TranslationStore.loadMerged(
            forDocId: record.id, language: "es", in: projectURL).isEmpty,
            "the table's batch is all-or-nothing")
        XCTAssertTrue(DepartmentRunState.reportLine(.ingested(outcome))?.contains(refusal) == true,
                      "the desk's row says it")
    }

    /// **A table the translator's permit stopped reaching mid-round is
    /// refused and said** (R6): briefed as a whole-book author, both tables
    /// are work; narrowed to her piece before the answer lands, her table's
    /// labels are written and the whole-book table's batch is refused by the
    /// door, by name, in the report.
    func test_aTableThePostureStoppedReachingMidRoundIsRefusedAndReported() async throws {
        let (ds, store, root) = try await openBook(chapterA: """
            ![Books](../figures/books.csv){#tbl:books}

            ![Hers](../figures/hers.csv){#tbl:hers}
            """, register: true)
        let books = try await store.createFigure(kind: .table, name: "books", piece: nil, table: ledger())
        let hers = try await store.createFigure(kind: .table, name: "hers", piece: "doc-a", table: ledger())
        await ds.awaitOpenFigureRenderForTesting()
        let environment = production(ds, store)
        let round = try await brief(environment)
        XCTAssertEqual(round.inputs.tableCells.map(\.figureId), [books.id, hers.id],
                       "premise: a whole-book author's round")

        try await rootChangesMyPermit(to: .author(.pieces(["doc-a"])), root: try XCTUnwrap(root), ds)
        let outcome = await ingest(answer(round, cells: round.inputs.tableCells.flatMap { table in
            table.cells.map { TranslatorReport.Cell(figureId: table.figureId, key: $0.key,
                                                    text: Self.spanish[$0.sourceText], verbatim: nil) }
        }), round, environment)

        XCTAssertEqual(outcome.cellsWritten, 3, "her table's three labels land")
        XCTAssertEqual(outcome.cellRefusals.count, 1)
        XCTAssertTrue(outcome.cellRefusals.first?.hasPrefix("Table books: ") == true,
                      "\(outcome.cellRefusals)")
        XCTAssertTrue(try TranslationStore.loadMerged(
            forDocId: books.id, language: "es", in: projectURL).isEmpty)
        XCTAssertEqual(try TranslationStore.loadMerged(
            forDocId: hers.id, language: "es", in: projectURL).count, 3)
    }

    /// **A malformed `cells` list rejects the cells, the paragraphs land,
    /// and the report says so** (plan ruling: cells are all-or-nothing per
    /// report).
    func test_aMalformedCellsListWritesNoCellButTheParagraphsLand() async throws {
        let (ds, store, _) = try await openBook(
            chapterA: "Opening.\n\n![Quarters](../figures/quarters.csv){#tbl:quarters}\n")
        let record = try await store.createFigure(kind: .table, name: "quarters", piece: nil, table: quarters())
        await ds.awaitOpenFigureRenderForTesting()
        let environment = production(ds, store)
        let round = try await brief(environment)

        let outcome = await ingest(answer(round, cells: [], cellsMalformed: true), round, environment)
        XCTAssertNil(outcome.rejection)
        XCTAssertEqual(outcome.entriesWritten, round.inputs.workList.count)
        XCTAssertGreaterThan(outcome.entriesWritten, 0, "premise: the paragraphs were work")
        XCTAssertEqual(outcome.cellsWritten, 0)
        XCTAssertEqual(outcome.cellRefusals,
                       [TranslatorOrchestrator.Environment.cellsMalformedSentence])
        XCTAssertTrue(try TranslationStore.loadMerged(
            forDocId: record.id, language: "es", in: projectURL).isEmpty)
    }

    /// **A table the round never briefed is refused, by name** — a cell the
    /// translator was never sent is never written, whatever the answer says.
    func test_aCellForATableTheRoundDidNotBriefIsRefused() async throws {
        let (ds, store, _) = try await openBook(
            chapterA: "Opening.\n\n![Quarters](../figures/quarters.csv){#tbl:quarters}\n")
        let record = try await store.createFigure(kind: .table, name: "quarters", piece: nil, table: quarters())
        await ds.awaitOpenFigureRenderForTesting()
        let live = try await table(store, record.id)
        let environment = production(ds, store)
        let round = try await brief(environment)
        let unbriefed = TranslatorOrchestrator.BriefedRound(
            inputs: TranslatorBriefing.Inputs(
                translatorName: "Elena Ruiz", language: "es", workList: round.inputs.workList),
            sourceHashes: round.sourceHashes)

        let outcome = await ingest(answer(round, cells: [
            .init(figureId: record.id, key: key(live, 0, 0), text: "Concepto", verbatim: nil),
        ]), unbriefed, environment)
        XCTAssertEqual(outcome.cellsWritten, 0)
        XCTAssertEqual(outcome.cellRefusals, [
            TranslatorOrchestrator.Environment.unbriefedTableSentence(name: "quarters", count: 1),
        ])
        XCTAssertTrue(try TranslationStore.loadMerged(
            forDocId: record.id, language: "es", in: projectURL).isEmpty)
    }

    /// The desk's copy names table cells beside paragraphs, and alone when a
    /// round had only cells; the round report counts them.
    func test_theDeskAndTheRoundReportCountTableCells() {
        XCTAssertEqual(DepartmentRunState.translating(3, cells: 4),
                       "Translating 3 paragraphs and 4 table cells\u{2026}")
        XCTAssertEqual(DepartmentRunState.translating(0, cells: 1), "Translating 1 table cell\u{2026}")
        XCTAssertEqual(DepartmentRunState.translating(2), "Translating 2 paragraphs\u{2026}")
        XCTAssertEqual(DepartmentRunState.landedLine(entries: 2, queries: 1, cells: 3),
                       "2 paragraphs translated \u{00b7} 3 table cells labelled \u{00b7} 1 question asked")
        XCTAssertEqual(DepartmentRunState.landedLine(entries: 0, queries: 0, cells: 1),
                       "1 table cell labelled")
        XCTAssertEqual(DepartmentRunState.landedLine(entries: 0, queries: 0),
                       "The round wrote nothing and asked nothing.")

        var round = TranslationRound(number: 1, language: "es", docId: "doc-a", startedAt: Date())
        XCTAssertFalse(TranslationRoundReport.countsLine(round).contains("table cell"))
        round.tableCells = .init(written: 2, refusals: ["Table cash: refused"])
        XCTAssertTrue(TranslationRoundReport.countsLine(round).hasSuffix("2 table cells labelled"))
        XCTAssertEqual(TranslationRoundReport.tableCellRefusals(round), ["Table cash: refused"])
    }

    // MARK: - Preflight and the other legs (Task 4)

    private func budgets(_ ds: DocumentStore, _ store: ProjectStore,
                         _ documentIds: [String]) async throws -> [String: Int] {
        try await TranslationPreflight.budgets(
            documentIds: documentIds, languages: ["es", "fr"], store: store,
            documentStore: ds, projectURL: projectURL)
    }

    /// **The pre-flight counts the table cells a Run would brief**: the five
    /// labels' words land on top of the paragraphs', a table used by both
    /// chapters is counted once for the book (its first piece's round labels
    /// it), and a stale label adds its prior translation — what the
    /// translator is shown. The control: the same book before the table
    /// existed. The disable experiment: drop the cells from `budgets` and
    /// every figure equals the control.
    func test_thePreflightCountsTheCellsARunWouldBrief() async throws {
        let line = "Opening.\n\n![Quarters](../figures/quarters.csv){#tbl:quarters}\n"
        let (ds, store, _) = try await openBook(chapterA: line, chapterB: line)
        let chapterBefore = try await budgets(ds, store, ["doc-a"])
        let bookBefore = try await budgets(ds, store, ["doc-a", "doc-b"])

        let record = try await store.createFigure(kind: .table, name: "quarters", piece: nil, table: quarters())
        await ds.awaitOpenFigureRenderForTesting()
        let live = try await table(store, record.id)
        let chapter = try await budgets(ds, store, ["doc-a"])
        XCTAssertEqual(chapter["es"], chapterBefore["es"].map { $0 + 5 },
                       "Item, Q1, Q2, Rent and Food")
        XCTAssertEqual(chapter["fr"], chapterBefore["fr"].map { $0 + 5 })
        let book = try await budgets(ds, store, ["doc-a", "doc-b"])
        XCTAssertEqual(book["es"], bookBefore["es"].map { $0 + 5 }, "the shared table once")

        // Spanish labelled — Item then edited — leaves one stale label: its
        // source and its prior answer are what a Run would brief.
        try await write(["Item", "Q1", "Q2", "Rent", "Food"].enumerated().map { index, word in
            let (r, c) = index < 3 ? (0, index) : (index - 2, 0)
            return .init(key: key(live, r, c), text: Self.spanish[word])
        }, figureId: record.id, table: live)
        let host = try await ds.openFigure(figureId: record.id)
        try await host.setCell(Cell(content: .value(.text("Line item"))), at: key(live, 0, 0))
        await ds.awaitOpenFigureRenderForTesting()
        await ds.closeFigure(figureId: record.id)
        let stale = try await budgets(ds, store, ["doc-a"])
        XCTAssertEqual(stale["es"], chapterBefore["es"].map { $0 + 3 },
                       "\"Line item\" and its prior \"Concepto\"")
    }

    /// **The spot-check, collator and cold legs see no cells** (plan
    /// ruling): after a round labels the chapter's table, the reader's and
    /// the collator's production briefings — the cold legs', and the base
    /// Ask the Collator narrows — brief the chapter's paragraphs alone: no
    /// cell id, no label, no Spanish label. Their inputs, and the gloss's,
    /// have no field a cell could ride in.
    func test_theReaderCollatorAndGlossLegsSeeNoCells() async throws {
        let (ds, store, _) = try await openBook(
            chapterA: "Opening.\n\n![Quarters](../figures/quarters.csv){#tbl:quarters}\n")
        let record = try await store.createFigure(kind: .table, name: "quarters", piece: nil, table: quarters())
        await ds.awaitOpenFigureRenderForTesting()
        let environment = production(ds, store)
        let round = try await brief(environment)
        let outcome = await ingest(answer(round), round, environment)
        XCTAssertEqual(outcome.cellsWritten, 5, "premise: the table is labelled")
        let sequence = try currentParagraphState(
            documentId: "doc-a", store: store, documentStore: ds, projectURL: projectURL).sequence

        let reader = try XCTUnwrap(try TranslationPipeline.Environment.readerBriefing(
            docId: "doc-a", language: "es", store: store, documentStore: ds, projectURL: projectURL))
        let collator = try XCTUnwrap(try TranslationPipeline.Environment.collatorBriefing(
            docId: "doc-a", language: "es", store: store, documentStore: ds, projectURL: projectURL))
        XCTAssertEqual(reader.paragraphs.map(\.paragraphId), sequence)
        XCTAssertEqual(collator.pairs.map(\.paragraphId), sequence)
        for message in [ReaderBriefing.compose(inputs: reader), CollatorBriefing.compose(inputs: collator)] {
            for absent in ["Concepto", "Alquiler", "Comida", "Q1", "[Table:", record.id] {
                XCTAssertFalse(message.contains(absent), "a cold leg was briefed \(absent)")
            }
        }
        let gloss = GlossBriefing.Inputs(
            language: "Spanish", authorLanguage: "English", textureLine: nil,
            before: nil, paragraph: "Hola.", after: nil)
        for inputs in [Mirror(reflecting: reader), Mirror(reflecting: collator), Mirror(reflecting: gloss)] {
            let fields = inputs.children.compactMap(\.label)
            XCTAssertFalse(fields.contains { $0.lowercased().contains("cell") }, "\(fields)")
            XCTAssertFalse(fields.contains { $0.lowercased().contains("table") }, "\(fields)")
        }
    }

    // MARK: - The register

    /// Another Mac roots the book and admits this one as an author of the
    /// whole book (`PostureSurfaceTests.makeForeignRoot`'s shape).
    private func makeForeignRoot() throws -> DeviceIdentity {
        let identities = try XCTUnwrap(Document.localIdentitiesForTesting)
        let root = DeviceIdentity.softwareForTesting()
        try RegistryWriter.write(
            DeviceRecord(
                device: root.fingerprint, name: "The other Mac", kind: .mac,
                actors: [DeviceActor.author.rawValue: root.fingerprint],
                madeAt: Date(timeIntervalSince1970: 1_000)),
            signedBy: root, in: projectURL)
        try RegistryWriter.write(
            PersonRecord(
                person: root.fingerprint, label: "Sam", ownName: "The other Mac",
                role: Permit.authorRole,
                admittedAt: Date(timeIntervalSince1970: 1_000),
                admittedBy: root.fingerprint),
            signedBy: root, in: projectURL)
        try RegistryWriter.write(
            DeviceRecord(
                device: identities.author.fingerprint, name: "This Mac", kind: .mac,
                actors: Dictionary(uniqueKeysWithValues: DeviceActor.allCases.map {
                    ($0.rawValue, identities[$0].fingerprint)
                }),
                madeAt: Date(timeIntervalSince1970: 2_000)),
            signedBy: identities.author, in: projectURL)
        try RegistryWriter.write(
            PersonRecord(
                person: identities.author.fingerprint, label: "Denver",
                ownName: "This Mac", role: Permit.authorRole,
                admittedAt: Date(timeIntervalSince1970: 2_000),
                admittedBy: root.fingerprint),
            signedBy: root, in: projectURL)
        return root
    }

    /// The root changes this Mac's permit, delivered through the presenter's
    /// registry route (`PostureSurfaceTests.rootChangesMyPermit`'s shape).
    private func rootChangesMyPermit(
        to permit: Permit, root: DeviceIdentity, _ store: DocumentStore
    ) async throws {
        let identities = try XCTUnwrap(Document.localIdentitiesForTesting)
        let mark = try OpLogStore.appliedPositions(
            ofDeviceIds: Set(identities.all.map(\.deviceId)),
            in: projectURL,
            trust: try TrustResolution.resolve(projectURL: projectURL, identities: identities))
        let rootCache = RegistryCache(
            fileURL: projectURL.appendingPathComponent("root-cache.json"),
            identity: root.fingerprint)
        _ = try RegistryAdmission.changePermit(
            person: identities.author.fingerprint,
            role: permit.wireRole, scope: permit.wireScope, pieces: permit.wirePieces,
            mark: mark,
            unsigned: permit.narrows ? .nothingApplied : nil,
            in: projectURL, by: root, cache: rootCache)
        store.presenterDidChangeSubitem(at: RegistryWriter.url(
            .people, fingerprint: identities.author.fingerprint, in: projectURL))
        await store.flushRegistryChangeForTesting()
        await store.postureSettled()
    }
}
