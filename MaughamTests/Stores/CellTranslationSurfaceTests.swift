import XCTest
@testable import Maugham
@testable import MaughamCore

/// **Where a writer sees a table's cell translations on the Mac** (report
/// plan 9e-1 Tasks 7–8): the figure card in translation review, the
/// Translation pane's Cells list and its Remove, and the inspector's
/// Translations lines with their way into review.
@MainActor
final class CellTranslationSurfaceTests: CellTranslationBookTestCase {

    // MARK: - The card in review (Task 7)

    /// **A card in es review shows the translated labels**: the store's card
    /// read in a review language carries that language's FRESH labels (what
    /// the es body prints), the source read carries none, and once "Rent"
    /// becomes "Rents" its stale translation drops out so the card shows the
    /// source — through the window's real cache.
    func test_aCardInEsReviewShowsTheFreshTranslations() async throws {
        let (ds, store, figureId) = try await openBook()
        let t = try await table(store, figureId)
        let (item, rent) = labels(t)
        try await write([.init(key: item, text: "Concepto"), .init(key: rent, text: "Alquiler")],
                        figureId: figureId, table: t)

        let plainRead = await ds.figureCardInputs()
        let plain = try XCTUnwrap(plainRead)
        XCTAssertNil(plain.language)
        XCTAssertTrue(plain.labels.isEmpty, "the source reads no translation")

        let cache = FigureCardCache()
        cache.attach(FigureCardCache.Source(readInLanguage: { [weak ds] in await ds?.figureCardInputs(language: $0) }))
        await cache.idle()
        XCTAssertEqual(cache.model(forFigureId: figureId)?.headerRows, [["Item", "Amount"]])
        cache.setReviewLanguage("es")
        await cache.idle()
        XCTAssertEqual(cache.model(forFigureId: figureId)?.headerRows, [["Concepto", "Amount"]])
        XCTAssertEqual(cache.model(forFigureId: figureId)?.bodyRows.first?.first, "Alquiler")

        let host = try await ds.openFigure(figureId: figureId)
        try await host.setCell(Cell(content: .value(.text("Rents"))), at: rent)
        await ds.awaitOpenFigureRenderForTesting()
        let esRead = await ds.figureCardInputs(language: "es")
        let es = try XCTUnwrap(esRead)
        XCTAssertEqual(es.labels[figureId], [item: "Concepto"], "a stale translation shows the source")
        await ds.closeFigure(figureId: figureId)
        cache.attach(nil)
    }

    // MARK: - Inspect and purge (Task 8)

    /// **The Cells list reads a table's text cells and orphans, and Remove
    /// purges an orphan as the author through the write door**: "Rent"
    /// turned into a number orphans its translation (listed at A2, never a
    /// row); Remove tombstones it, after which the list holds no orphan and
    /// the live rows are untouched.
    func test_theCellsListShowsAnOrphan_andRemovePurgesIt() async throws {
        let (ds, store, figureId) = try await openBook()
        let t = try await table(store, figureId)
        let (item, rent) = labels(t)
        try await write([.init(key: item, text: "Concepto"), .init(key: rent, text: "Alquiler")],
                        figureId: figureId, table: t)
        let host = try await ds.openFigure(figureId: figureId)
        try await host.setCell(Cell(content: .value(.number(5))), at: rent)
        await ds.awaitOpenFigureRenderForTesting()

        let before = try await ds.figureCellTranslations(figureId: figureId, languages: ["es"])
        let read = try XCTUnwrap(before?["es"])
        XCTAssertEqual(TranslationCellRows.rows(read.derived, table: read.table).map(\.address), ["A1", "B1"])
        let orphans = TranslationCellRows.orphanRows(read.derived, table: read.table)
        XCTAssertEqual(orphans.map(\.address), ["A2"])
        XCTAssertEqual(orphans.map(\.text), ["Alquiler"])

        let refusal = await TranslationCellRows.purge(
            orphans, figureId: figureId, language: "es", table: read.table, projectURL: projectURL,
            identities: try XCTUnwrap(Document.localIdentitiesForTesting),
            deviceState: try XCTUnwrap(Document.deviceStateForTesting))
        XCTAssertNil(refusal)
        let after = try await ds.figureCellTranslations(figureId: figureId, languages: ["es"])
        let purged = try XCTUnwrap(after?["es"])
        XCTAssertTrue(purged.derived.orphans.isEmpty, "the orphan is gone")
        XCTAssertEqual(purged.derived.entries.first?.translatedText, "Concepto", "live rows untouched")
        await ds.closeFigure(figureId: figureId)
    }

    /// **A refused purge is said**: its sentence comes back and goes to the
    /// window's notice line (`MaughamEvent.postNotice`), and nothing is
    /// written.
    func test_aRefusedPurgeIsSaidAsANotice() async throws {
        let (ds, store, figureId) = try await openBook()
        let t = try await table(store, figureId)
        defer { withExtendedLifetime(ds) {} }   // the store holds its DocumentStore weakly
        let orphan = TranslationCellRows.OrphanRow(id: "x", address: "A2", text: "Alquiler", key: labels(t).rent)
        var notices: [String] = []
        let token = NotificationCenter.default.addObserver( // adr-0021-ok: a test observing the production post, not a production subscription
            forName: .maughamDocumentNotice, object: nil, queue: nil) { note in
            if let message = note.userInfo?[MaughamEvent.noticeMessageKey] as? String { notices.append(message) }
        }
        defer { NotificationCenter.default.removeObserver(token) }
        let refusal = await TranslationCellRows.purge(
            [orphan], figureId: figureId, language: "not a tag", table: t, projectURL: projectURL,
            identities: try XCTUnwrap(Document.localIdentitiesForTesting),
            deviceState: try XCTUnwrap(Document.deviceStateForTesting))
        let sentence = try XCTUnwrap(refusal)
        XCTAssertEqual(notices, [sentence])
        XCTAssertTrue(TranslationStore.languages(forDocId: figureId, in: projectURL).isEmpty, "nothing written")
    }

    /// **The inspector's Translations lines**: one per language the book is
    /// translated into, counting fresh of the table's text cells; its Review
    /// reveals the table's line in that edition.
    func test_theInspectorCountsEachLanguage_andReviewOpensTheEdition() async throws {
        let (ds, store, figureId) = try await openBook()
        let t = try await table(store, figureId)
        let (item, rent) = labels(t)
        try await write([.init(key: item, text: "Concepto"), .init(key: rent, text: "Alquiler")],
                        figureId: figureId, table: t)
        try await write([.init(key: item, text: "Article")], language: "fr", figureId: figureId, table: t)

        let model = FigureInspectorModel(figureId: figureId)
        await model.loadTranslations(documentStore: ds)
        XCTAssertEqual(model.translations.map(\.language), ["es", "fr"])
        XCTAssertEqual(model.translations.map(\.text), ["2 of 3 cells", "1 of 3 cells"])

        let destination = FigureUseTravel.destination(
            for: FigureListing.Use(docId: "doc-a", lineIndex: 2), store: store, documentStore: ds,
            language: "es")
        guard case .paragraph(let reveal) = destination else { return XCTFail("a paragraph: \(destination)") }
        XCTAssertEqual(reveal.language, "es")
        XCTAssertEqual(reveal.docId, "doc-a")
    }
}
