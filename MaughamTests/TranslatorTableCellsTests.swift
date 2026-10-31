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
        chapterA: String, register: Bool = false
    ) async throws -> (DocumentStore, ProjectStore, root: DeviceIdentity?) {
        try chapterA.write(to: file("manuscript/a.md"), atomically: true, encoding: .utf8)
        try "Chapter B.\n".write(to: file("manuscript/b.md"), atomically: true, encoding: .utf8)
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
