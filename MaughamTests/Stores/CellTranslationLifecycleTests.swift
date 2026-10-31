import XCTest
@testable import Maugham
@testable import MaughamCore

/// **A table's cell translations across the figure's life** (report plan
/// 9e-1 Task 9): a removed table's translations are inert — listed, counted
/// and shown nowhere — and come back with a restore (R4), and Empty Trash
/// leaves them; a parked table is not gated and its return brings them back;
/// a rename leaves them alone; a promotion carries none (R5). Each is keyed
/// by the figure id, so every one of these is the registry's answer.
@MainActor
final class CellTranslationLifecycleTests: CellTranslationBookTestCase {

    /// The chapter's figure line, as a piece the coverage gate reads.
    private let piece = FigureUse.Piece(
        path: "manuscript/a.md", sequence: ["p1"],
        paragraphs: ["p1": "![Cash flows](../figures/cash.csv){#tbl:cash}"])

    /// Every Mac surface's answer about the table's es translations at once:
    /// the gate's used tables, the fresh labels a body prints, the card in
    /// review, the pane's and inspector's read, the line under the caret,
    /// the inspector's languages and the desk's layer.
    private struct Seen: Equatable {
        var gated: [String]
        var printed: [CellKey: String]
        var card: [CellKey: String]
        var inspected: Int?
        var underCaret: String?
        var languages: [String]
        var layer: Set<String>
    }

    private func seen(_ ds: DocumentStore, _ store: ProjectStore, _ figureId: String) async throws -> Seen {
        let figures = await store.publishFigures()
        let trust = try TrustResolution.resolve(
            projectURL: projectURL, identities: try XCTUnwrap(Document.localIdentitiesForTesting))
        let printed = try FigureUse.freshLabels(
            language: "es", figures: figures, projectURL: projectURL, trust: { trust })[figureId] ?? [:]
        let cards = await ds.figureCardInputs(language: "es")
        let reads = try await ds.figureCellTranslations(figureId: figureId, languages: ["es"])
        return Seen(
            gated: FigureUse.tables(in: [piece], figures: figures).readable.map(\.record.id),
            printed: printed,
            card: cards?.labels[figureId] ?? [:],
            inspected: reads?["es"]?.derived.freshCount,
            underCaret: TranslationCellRows.tableFigure(
                inParagraph: piece.paragraphs["p1"]!, documentPath: piece.path,
                records: store.manifest.figures ?? [])?.id,
            languages: DocumentStore.bookTranslationLanguages(in: projectURL, manifest: store.manifest),
            layer: await EditionStatus.layerLanguages(in: store, projectURL: projectURL, scope: ["doc-a"]))
    }

    private func translated(_ figureId: String, _ item: CellKey) -> Seen {
        Seen(gated: [figureId], printed: [item: "Concepto"], card: [item: "Concepto"], inspected: 1,
             underCaret: figureId, languages: ["es"], layer: ["es"])
    }

    private static let nowhere = Seen(gated: [], printed: [:], card: [:], inspected: nil,
                                      underCaret: nil, languages: [], layer: [])

    // MARK: - Removed (R4)

    /// **A removed table's translations are inert and re-attach on
    /// restore**: removed, the file stays on disk but no surface lists,
    /// counts or shows it — the gate, a body, the card, the pane, the
    /// inspector, the desk's layer, nor MCP (unknown figure); restored, every
    /// surface shows the same translation again.
    func test_aRemovedTablesTranslationsAreInert_andARestoreReattachesThem() async throws {
        let (ds, store, figureId) = try await openBook()
        let t = try await table(store, figureId)
        let item = labels(t).item
        try await write([.init(key: item, text: "Concepto")], figureId: figureId, table: t)
        let before = try await seen(ds, store, figureId)
        XCTAssertEqual(before, translated(figureId, item), "premise: every surface shows it")

        let entry = try await store.removeFigure(id: figureId)
        let removed = try await seen(ds, store, figureId)
        XCTAssertEqual(removed, Self.nowhere)
        XCTAssertEqual(TranslationStore.languages(forDocId: figureId, in: projectURL), ["es"],
                       "inert, not swept: the file stays")

        _ = try await store.restoreTrashEntry(id: entry.id)
        await ds.awaitOpenFigureRenderForTesting()
        let restored = try await seen(ds, store, figureId)
        XCTAssertEqual(restored, translated(figureId, item), "re-attached, as it was")
    }

    /// **Empty Trash leaves a removed table's translations**, as it leaves
    /// the table's own stream (R4): append-only history is never swept.
    func test_emptyTrashLeavesARemovedTablesTranslations() async throws {
        let (ds, store, figureId) = try await openBook()
        defer { withExtendedLifetime(ds) {} }
        let t = try await table(store, figureId)
        try await write([.init(key: labels(t).item, text: "Concepto")], figureId: figureId, table: t)
        try await store.removeFigure(id: figureId)
        try await store.emptyTrash()
        XCTAssertEqual(TranslationStore.languages(forDocId: figureId, in: projectURL), ["es"])
    }

    // MARK: - Parked

    /// **A parked table is not gated, and its return re-attaches its
    /// translations**: sent to Research, the line no longer prints a table,
    /// so neither the gate nor a body nor the card nor the pane reads its
    /// translations; brought back (the same id), all of them do again.
    func test_aParkedTableIsNotGated_andItsReturnReattaches() async throws {
        let (ds, store, figureId) = try await openBook()
        let t = try await table(store, figureId)
        let item = labels(t).item
        try await write([.init(key: item, text: "Concepto")], figureId: figureId, table: t)

        let copy = try await store.sendToResearch(figureId: figureId, scope: .document("doc-a"))
        await ds.awaitOpenFigureRenderForTesting()
        let parked = try await seen(ds, store, figureId)
        XCTAssertEqual(parked.gated, [], "a parked table is never gated")
        XCTAssertEqual(parked.printed, [:])
        XCTAssertEqual(parked.card, [:])
        XCTAssertNil(parked.inspected)

        let back = try await store.bringBack(researchItemId: copy.id, piece: nil)
        await ds.awaitOpenFigureRenderForTesting()
        XCTAssertEqual(back.record.id, figureId, "premise: the return keeps the id")
        let returned = try await seen(ds, store, figureId)
        XCTAssertEqual(returned.gated, [figureId])
        XCTAssertEqual(returned.printed, [item: "Concepto"])
        XCTAssertEqual(returned.card, [item: "Concepto"])
        XCTAssertEqual(returned.inspected, 1)
    }

    // MARK: - Renamed

    /// **A rename leaves the cell translations untouched**: they are keyed
    /// by the figure's id, so a new name and path print the same labels.
    func test_aRenameLeavesTheCellTranslationsUntouched() async throws {
        let (ds, store, figureId) = try await openBook()
        let t = try await table(store, figureId)
        let item = labels(t).item
        try await write([.init(key: item, text: "Concepto")], figureId: figureId, table: t)

        let renamed = try await store.renameFigure(id: figureId, to: "cashflow")
        await ds.awaitOpenFigureRenderForTesting()
        XCTAssertEqual(renamed.path, "figures/cashflow.csv", "premise: the path moved")
        let reads = try await ds.figureCellTranslations(figureId: figureId, languages: ["es"])
        XCTAssertEqual(reads?["es"]?.derived.freshLabels, [item: "Concepto"])
        let cards = await ds.figureCardInputs(language: "es")
        XCTAssertEqual(cards?.labels[figureId], [item: "Concepto"])
    }

    // MARK: - Promoted (R5)

    /// **A promotion carries no cell translations**, as it carries no piece
    /// translations: the piece's own table goes to the new project with its
    /// id, and its translation file does not.
    func test_aPromotionCarriesNoCellTranslations() async throws {
        let collection = try await ProjectFactory.createCollectionProject(named: "Anthology", in: projectURL)
        let projectStore = try await ProjectStore.load(from: collection)
        let piece = try await projectStore.addLoosePiece(title: "Story A", format: .markdown)
        let ds = try await DocumentStore.open(url: collection)
        projectStore.documentStore = ds
        ds.projectStore = projectStore
        defer { withExtendedLifetime(ds) {} }
        let doc = try await Document.load(
            url: collection.appendingPathComponent(try XCTUnwrap(piece.path)),
            actor: .author, session: "boot", presenter: nil)
        doc.setFullText("As @tbl:own shows.\n")
        await doc.close()

        var t = FigureTable(rows: 1, columns: 1)
        let a1 = CellKey(row: t.rows[0], column: t.columns[0])
        t.setCell(Cell(content: .value(.text("Rent"))), at: a1)
        let own = try await projectStore.createFigure(kind: .table, name: "own", piece: piece.id, table: t)
        _ = try await TranslationWritePipeline.performCells(
            entries: [.init(key: a1, text: "Alquiler")], language: "es", figureId: own.id,
            table: t, projectURL: collection, actor: .translator,
            identities: try XCTUnwrap(Document.localIdentitiesForTesting),
            deviceState: try XCTUnwrap(Document.deviceStateForTesting))
        XCTAssertEqual(TranslationStore.languages(forDocId: own.id, in: collection), ["es"], "premise")

        let promotion = try await projectStore.promotePieceToProject(
            pieceId: piece.id, destination: projectURL.appendingPathComponent("Promoted Story A"))
        let promoted = try await ProjectStore.load(from: promotion.url)
        XCTAssertTrue(promoted.manifest.figures?.contains { $0.id == own.id } == true,
                      "premise: the table went with the piece, by its id")
        XCTAssertTrue(TranslationStore.languagesByDocId(in: promotion.url).isEmpty,
                      "no translation travelled")
    }

    // MARK: - An unused table's unreadable file (final fix wave, M1)

    /// **An unreadable translation file for a table the edition does not
    /// print never fails the body** (report plan 9e-1 final fix wave, M1).
    /// The snapshot holds every registered table, and the coverage gate reads
    /// only the used ones, so the gate passes this book; the resolve door's
    /// label read must not then throw over the unused table. It is left out
    /// (it prints nothing here anyway) and the used table still prints its
    /// translation.
    ///
    /// The disable experiment: put `try` back on the `coverage` call in
    /// `FigureUse.freshLabels` and the call below throws
    /// `OpLogStore.ReadError.unreadableFile` naming the squatted file.
    func test_anUnusedTablesUnreadableTranslationFileFailsNoBody() async throws {
        let (ds, store, figureId) = try await openBook()
        _ = ds
        let t = try await table(store, figureId)
        let item = labels(t).item
        try await write([.init(key: item, text: "Concepto")], figureId: figureId, table: t)

        let unused = try await store.createFigure(kind: .table, name: "spare", piece: nil, table: t)
        try await write([.init(key: item, text: "Repuesto")], figureId: unused.id, table: t)
        // A second actor's file for the same (figure, language), squatted by a
        // directory: present and unreadable (the gate suite's primitive).
        let squat = try TranslationStore.fileURL(
            forDocId: unused.id, language: "es",
            deviceSlug: DeviceSlug.make(from: "bad"), in: projectURL)
        try FileManager.default.createDirectory(at: squat, withIntermediateDirectories: true)

        let figures = await store.publishFigures()
        XCTAssertEqual(FigureUse.tables(in: [piece], figures: figures).readable.map(\.record.id),
                       [figureId], "premise: the gate reads the used table alone")
        let trust = try TrustResolution.resolve(
            projectURL: projectURL, identities: try XCTUnwrap(Document.localIdentitiesForTesting))
        XCTAssertThrowsError(try FigureUse.coverage(
            of: FigureUse.Table(record: unused, table: t), language: "es",
            projectURL: projectURL, trust: trust), "premise: the spare's file will not read")

        let printed = try FigureUse.freshLabels(
            language: "es", figures: figures, projectURL: projectURL, trust: { trust })
        XCTAssertEqual(printed, [figureId: [item: "Concepto"]],
                       "the used table prints; the unreadable unused one is left out")
    }
}
