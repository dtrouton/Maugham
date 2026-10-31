import XCTest
@testable import Maugham
@testable import MaughamCore

/// **Where a writer sees a table's cell translations on the Mac** (report
/// plan 9e-1 Tasks 7–8): the figure card in translation review.
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
}
