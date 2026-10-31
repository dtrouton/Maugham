import XCTest
@testable import MaughamPhone
import MaughamCore

/// A download double that EVICTS: every file it is told about reads empty, as
/// an evicted iCloud file does (no error), until `download(at:)` is asked for
/// it — which puts the bytes back. A load that reads before it downloads sees
/// an empty stream. Files named in `failing` never download.
private final class EvictingDownloader: UbiquitousDownloader, @unchecked Sendable {
    private let lock = NSLock()
    private var stash: [String: (url: URL, bytes: Data)] = [:]
    private var asked: [String] = []
    private let failing: Set<String>
    private let neverRestoring: Set<String>

    /// `neverRestoring`: names whose download reports success but leaves the
    /// file empty, as a remembered `.downloaded` over a re-evicted file does.
    init(failing: Set<String> = [], neverRestoring: Set<String> = []) {
        self.failing = failing
        self.neverRestoring = neverRestoring
    }

    /// Empty `url` in place, keeping its bytes to restore on download.
    func evict(_ url: URL) throws {
        let bytes = try Data(contentsOf: url)
        try Data().write(to: url)
        lock.withLock { stash[url.lastPathComponent] = (url, bytes) }
    }

    /// The file names downloaded, in order.
    var downloaded: [String] { lock.withLock { asked } }

    func fileSize(at url: URL) -> Int64? { nil }

    func download(at url: URL) -> AsyncThrowingStream<Double, Error> {
        let name = url.lastPathComponent
        return AsyncThrowingStream { continuation in
            if failing.contains(name) {
                continuation.finish(throwing: CocoaError(.fileReadUnknown))
                return
            }
            let entry = lock.withLock { () -> (url: URL, bytes: Data)? in
                asked.append(name)
                return stash.removeValue(forKey: name)
            }
            if let entry, !neverRestoring.contains(name) { try? entry.bytes.write(to: entry.url) }
            continuation.yield(1.0)
            continuation.finish()
        }
    }
}

/// Report plan 9b Task 4: the phone loads a book's figures through Core —
/// op logs downloaded first, trust resolved once, workbook assembled, cards
/// built by `FigureCardBook`.
@MainActor
final class PhoneFigureBookTests: XCTestCase {

    private let rows = [RowID("r1aaaaaa"), RowID("r2bbbbbb"), RowID("r3cccccc")]
    private let cols = [ColumnID("c1dddddd"), ColumnID("c2eeeeee")]
    private let tableId = "fig-0a1b2c3d"
    private let imageId = "fig-4e5f6a7b"
    private let docPath = "chapters/one.md"
    private var counter = 0

    // MARK: - Fixture (Core writers only)

    private func op(_ id: String, _ kind: OpKind, _ payload: FigureOpPayload) -> Op {
        counter += 1
        return Op(opId: String(format: "op%04d", counter), docId: id,
                  at: Date(timeIntervalSince1970: TimeInterval(1_000 + counter)),
                  device: "mac", session: "s", kind: kind, changes: [], figure: payload)
    }

    private func write(_ ops: [Op], docId: String, in root: URL) async throws {
        let url = try OpLogStore.opLogFileURL(
            forDocId: docId, deviceSlug: DeviceSlug.make(from: "mac"), in: root)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try await JSONLAppendStore<Op>(fileURL: url).appendBatch(ops)
    }

    private func cell(_ r: Int, _ c: Int, _ content: CellContent, format: CellFormat = CellFormat()) -> Op {
        op(tableId, .figureCellSet, FigureOpPayload(
            cell: CellKey(row: rows[r], column: cols[c]),
            next: Cell(content: content, format: format), prior: nil))
    }

    /// A 3×2 table: A1 "Total", B1 `=SUM(B2:B3)`, B2 12000, B3 345.6 — so the
    /// card shows 12345.6 only if the formula computed. Optionally an image
    /// figure and a publish config naming the book's language.
    private func fixture(language: String? = nil, sumFormat: CellFormat = CellFormat(),
                         withImage: Bool = false) async throws -> (URL, ProjectManifest) {
        let root = TestTemp.root.appendingPathComponent("PhoneFigureBook-\(UUID().uuidString)")
        var skeleton = [op(tableId, .figureCreate, FigureOpPayload(kind: .table))]
        var after: RowID?
        for r in rows {
            skeleton.append(op(tableId, .figureStructure, FigureOpPayload(structure: .insertRow(r, after: after))))
            after = r
        }
        var afterC: ColumnID?
        for c in cols {
            skeleton.append(op(tableId, .figureStructure, FigureOpPayload(structure: .insertColumn(c, after: afterC))))
            afterC = c
        }
        let table = FigureDeriver.derive(skeleton).table
        guard case .success(let sum) = FormulaParser.parse("SUM(B2:B3)", in: table) else {
            XCTFail("SUM(B2:B3) did not parse"); throw CancellationError()
        }
        let ops = skeleton + [
            cell(0, 0, .value(.text("Total"))),
            cell(0, 1, .formula(sum), format: sumFormat),
            cell(1, 1, .value(.number(12_000))),
            cell(2, 1, .value(.number(345.6))),
        ]
        try await write(ops, docId: tableId, in: root)

        var records = [FigureRecord(id: tableId, name: "cash", kind: .table, piece: nil,
                                    path: "figures/cash.csv")]
        if withImage {
            try await write([op(imageId, .figureCreate, FigureOpPayload(kind: .image)),
                             op(imageId, .figureImageSet, FigureOpPayload(
                                image: FigureImageRef(filename: "map.png", contentHash: "h")))],
                            docId: imageId, in: root)
            records.append(FigureRecord(id: imageId, name: "map", kind: .image, piece: nil,
                                        path: "figures/map.png"))
        }
        if let language {
            let config = BookLanguage.configURL(in: root)
            try FileManager.default.createDirectory(
                at: config.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(#"{"metadata":{"title":"T","language":"\#(language)"}}"#.utf8).write(to: config)
        }
        let manifest = ProjectManifest(
            type: .novel, title: "T", author: "A", created: Date(), modified: Date(),
            structure: [], research: [], figures: records)
        return (root, manifest)
    }

    private func loader(_ downloader: UbiquitousDownloader = EvictingDownloader(),
                        region: String? = "US",
                        resolveTrust: @escaping PhoneFigureBook.ResolveTrust = PhoneFigureBook.liveTrust
    ) -> PhoneFigureBook {
        PhoneFigureBook(downloads: DownloadCoordinator(downloader: downloader),
                        region: region, resolveTrust: resolveTrust)
    }

    private func shown(_ card: FigureCardModel?) -> [String] {
        ((card?.headerRows ?? []) + (card?.bodyRows ?? [])).flatMap { $0 }
    }

    // MARK: - Tests

    func test_aTableFiguresCardShowsTheComputedSum() async throws {
        let (root, manifest) = try await fixture()
        let book = loader()
        let loaded = await book.load(manifest: manifest, projectURL: root)
        XCTAssertNotNil(loaded)
        let card = book.card(forLinePath: "../figures/cash.csv", documentPath: docPath)
        XCTAssertEqual(card?.kind, .table)
        XCTAssertTrue(shown(card).contains("12345.6"),
                      "=SUM(B2:B3) computes through Core's workbook: \(shown(card))")
    }

    /// The book's language reaches the card from its publish config, and a tag
    /// with a region keeps it whatever the device's. (A bare `es` borrows the
    /// device's region, as the Mac card borrows the Mac's — es_US prints the
    /// same separators as en_US, so no number assertion could see it.)
    func test_aSpanishBookFormatsInItsLanguage_withTheRegionForcedToUS() async throws {
        let grouped = CellFormat(number: .number(decimals: 1, grouping: true))

        let (spain, spanish) = try await fixture(language: "es-ES", sumFormat: grouped)
        let es = loader(region: "US")
        await es.load(manifest: spanish, projectURL: spain)
        XCTAssertTrue(shown(es.card(forLinePath: "../figures/cash.csv", documentPath: docPath))
            .contains("12.345,6"))
    }

    func test_everyFileIsDownloadedBeforeItIsRead() async throws {
        let (root, manifest) = try await fixture(language: "es-ES", withImage: true)
        let downloader = EvictingDownloader()
        let opFiles = OpLogStore.opLogFileURLs(forDocId: tableId, in: root)
            + OpLogStore.opLogFileURLs(forDocId: imageId, in: root)
        XCTAssertEqual(opFiles.count, 2)
        for file in opFiles + [BookLanguage.configURL(in: root)] { try downloader.evict(file) }

        let book = loader(downloader)
        await book.load(manifest: manifest, projectURL: root)

        XCTAssertEqual(Set(downloader.downloaded),
                       Set((opFiles + [BookLanguage.configURL(in: root)]).map(\.lastPathComponent)))
        let card = book.card(forLinePath: "../figures/cash.csv", documentPath: docPath)
        XCTAssertTrue(shown(card).contains("12345,6"),
                      "an evicted stream or config read before its download shows empty or English: \(shown(card))")
        XCTAssertEqual(book.card(forLinePath: "../figures/map.png", documentPath: docPath)?.kind, .image)
    }

    func test_aFigureWhoseStreamWillNotDownloadIsLeftOut_neverShownEmpty() async throws {
        let (root, manifest) = try await fixture(withImage: true)
        let tableFile = try XCTUnwrap(OpLogStore.opLogFileURLs(forDocId: tableId, in: root).first)
        let book = loader(EvictingDownloader(failing: [tableFile.lastPathComponent]))
        let loaded = await book.load(manifest: manifest, projectURL: root)
        XCTAssertNil(loaded?.models[tableId], "no card rather than an empty table")
        XCTAssertNil(book.card(forLinePath: "../figures/cash.csv", documentPath: docPath))
        XCTAssertEqual(loaded?.models[imageId]?.kind, .image)
    }

    func test_aDownloadThatSucceedsButReadsEmptyIsLeftOut_neverAnEmptyTable() async throws {
        let (root, manifest) = try await fixture(withImage: true)
        let tableFile = try XCTUnwrap(OpLogStore.opLogFileURLs(forDocId: tableId, in: root).first)
        let downloader = EvictingDownloader(neverRestoring: [tableFile.lastPathComponent])
        try downloader.evict(tableFile)
        let book = loader(downloader)
        let loaded = await book.load(manifest: manifest, projectURL: root)
        XCTAssertTrue(downloader.downloaded.contains(tableFile.lastPathComponent),
                      "the download was asked and reported success")
        XCTAssertNil(loaded?.models[tableId], "an empty read folds to no kind: no card, never an empty table")
        XCTAssertNil(book.card(forLinePath: "../figures/cash.csv", documentPath: docPath))
        XCTAssertEqual(loaded?.models[imageId]?.kind, .image)
    }

    /// A one-cell table figure whose A1 holds `content`, written through Core.
    private func oneCellFigure(_ id: String, _ content: CellContent, in root: URL) async throws {
        try await write([
            op(id, .figureCreate, FigureOpPayload(kind: .table)),
            op(id, .figureStructure, FigureOpPayload(structure: .insertRow(rows[0], after: nil))),
            op(id, .figureStructure, FigureOpPayload(structure: .insertColumn(cols[0], after: nil))),
            op(id, .figureCellSet, FigureOpPayload(
                cell: CellKey(row: rows[0], column: cols[0]), next: Cell(content: content), prior: nil)),
        ], docId: id, in: root)
    }

    /// `=<name>!A1` parsed against a one-cell table, the name bound to `id`.
    private func readsA1(of name: String, id: String) throws -> CellContent {
        let one = FigureTable(rows: 1, columns: 1)
        let names = FormulaNames(figures: [.init(id: id, name: name, table: one)])
        guard case .success(let f) = FormulaParser.parse("\(name)!A1", in: one, names: names) else {
            XCTFail("\(name)!A1 did not parse"); throw CancellationError()
        }
        return .formula(f)
    }

    func test_aFigureReadingALeftOutOne_isLeftOutTransitively_butAnAuthorsREFShows() async throws {
        let root = TestTemp.root.appendingPathComponent("PhoneFigureBook-\(UUID().uuidString)")
        let a = "fig-aaaa0001", b = "fig-bbbb0002", c = "fig-cccc0003", d = "fig-dddd0004"
        try await oneCellFigure(a, .value(.number(5)), in: root)
        try await oneCellFigure(b, try readsA1(of: "alpha", id: a), in: root)
        try await oneCellFigure(c, try readsA1(of: "beta", id: b), in: root)
        // D reads a figure the registry no longer holds: the author's own #REF!.
        try await oneCellFigure(d, try readsA1(of: "ghost", id: "fig-eeee0005"), in: root)
        let records = [("alpha", a), ("beta", b), ("gamma", c), ("delta", d)].map {
            FigureRecord(id: $0.1, name: $0.0, kind: .table, piece: nil, path: "figures/\($0.0).csv")
        }
        let manifest = ProjectManifest(
            type: .novel, title: "T", author: "A", created: Date(), modified: Date(),
            structure: [], research: [], figures: records)

        let aFile = try XCTUnwrap(OpLogStore.opLogFileURLs(forDocId: a, in: root).first)
        let downloader = EvictingDownloader(neverRestoring: [aFile.lastPathComponent])
        try downloader.evict(aFile)
        let book = loader(downloader)
        let result = await book.load(manifest: manifest, projectURL: root)
        let loaded = try XCTUnwrap(result)

        XCTAssertNil(loaded.models[a], "evicted")
        XCTAssertNil(loaded.models[b], "reads the evicted figure: no #REF! the author did not write")
        XCTAssertNil(loaded.models[c], "reads it through B")
        XCTAssertEqual(shown(loaded.models[d]), [FormulaError.ref.rawValue],
                       "a reference to a figure that no longer exists is the author's #REF!, still shown")
    }

    /// **A figure suggestion on the phone reads with the book's names and
    /// language** (report plan 9c-1 Task 7, fix round 1 I3): `=alpha!A1`
    /// names the other figure, never a `#REF!` the author did not write,
    /// and a value formats in the book's language — through this one reader.
    func test_theSuggestionReadingNamesOtherFiguresAndUsesTheBooksLanguage() async throws {
        let root = TestTemp.root.appendingPathComponent("PhoneFigureBook-\(UUID().uuidString)")
        let a = "fig-aaaa0001", b = "fig-bbbb0002"
        try await oneCellFigure(a, .value(.number(5)), in: root)
        try await oneCellFigure(b, .value(.number(1)), in: root)
        let config = BookLanguage.configURL(in: root)
        try FileManager.default.createDirectory(
            at: config.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"metadata":{"title":"T","language":"es-ES"}}"#.utf8).write(to: config)
        let manifest = ProjectManifest(
            type: .novel, title: "T", author: "A", created: Date(), modified: Date(),
            structure: [], research: [],
            figures: [FigureRecord(id: a, name: "alpha", kind: .table, piece: nil, path: "figures/alpha.csv"),
                      FigureRecord(id: b, name: "beta", kind: .table, piece: nil, path: "figures/beta.csv")])
        let book = loader()
        let read = await book.suggestionReading(projectURL: root, opened: manifest)
        let reading = try XCTUnwrap(read)

        let alphaTable = try XCTUnwrap(reading.names.table(id: a))
        let betaTable = try XCTUnwrap(reading.names.table(id: b))
        guard case .success(let f) = FormulaParser.parse("alpha!A1", in: betaTable, names: reading.names) else {
            return XCTFail("alpha!A1 did not parse")
        }
        XCTAssertNotNil(alphaTable)
        let proposal = Cell(content: .formula(f))
        XCTAssertEqual(SuggestionDisplay.cellText(proposal, table: betaTable, names: reading.names,
                                                  locale: reading.locale), "=alpha!A1")
        XCTAssertNotEqual(SuggestionDisplay.cellText(proposal, table: betaTable, names: .empty,
                                                     locale: reading.locale), "=alpha!A1",
                          "premise: empty names could not have named it")
        XCTAssertEqual(SuggestionDisplay.cellText(Cell(content: .value(.number(11.5))), table: betaTable,
                                                  names: reading.names, locale: reading.locale), "11,5")
    }

    func test_trustResolvesOncePerLoad() async throws {
        let (root, manifest) = try await fixture(withImage: true)
        let calls = Counter()
        let book = loader(resolveTrust: { url in
            await calls.bump()
            return try await PhoneFigureBook.liveTrust(url)
        })
        await book.load(manifest: manifest, projectURL: root)
        XCTAssertEqual(book.trustResolutions, 1)
        let afterOne = await calls.value
        XCTAssertEqual(afterOne, 1, "two figures, one resolution")
        await book.load(manifest: manifest, projectURL: root)
        let afterTwo = await calls.value
        XCTAssertEqual(afterTwo, 2)
    }

    func test_aBookWithNoFiguresLoadsNothing_andResolvesNoTrust() async throws {
        let (root, manifest) = try await fixture()
        var none = manifest
        none.figures = nil
        let book = loader()
        let loaded = await book.load(manifest: none, projectURL: root)
        XCTAssertNil(loaded)
        XCTAssertEqual(book.trustResolutions, 0)
    }

    /// A picture line outside `figures/` in a book with no figure registry
    /// still draws its picture (report plan 9b Task 5): the line rule answers
    /// `.image` and the URL resolves, though no card was built. A `figures/`
    /// path the registry does not name plans as not downloaded yet, never
    /// "Figure removed": the phone cannot tell removed from not yet synced.
    /// **The Annotations tab reuses one book per project** (final review M7):
    /// a second figure-suggestion detail reads the kept answer — no second
    /// trust resolve, download or fold — until the tab reloads.
    func test_annotationsReuseOneBookPerProjectUntilTheNextReload() async throws {
        let (root, manifest) = try await fixture()
        try ProjectManifest.makeEncoder().encode(manifest)
            .write(to: root.appendingPathComponent(ProjectManifest.fileName))
        let downloads = DownloadCoordinator(downloader: EvictingDownloader())
        let browser = ProjectsBrowser(downloads: downloads)
        await browser.refresh(root: root.deletingLastPathComponent())
        let project = try XCTUnwrap(browser.projects.first { $0.url.standardizedFileURL == root.standardizedFileURL })
        var made: [PhoneFigureBook] = []
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "annotations-books-\(UUID().uuidString)"))
        let store = AnnotationsStore(
            projectsBrowser: browser, downloads: downloads, recents: RecentsTracker(defaults: defaults),
            makeFigureBook: { downloads in
                let book = PhoneFigureBook(downloads: downloads, region: "US")
                made.append(book)
                return book
            })

        let first = await store.figureReading(projectURL: project.url)
        XCTAssertNotNil(first)
        _ = await store.figureReading(projectURL: project.url)
        XCTAssertEqual(made.count, 1, "one book for the project")
        XCTAssertEqual(made.first?.trustResolutions, 1, "the second detail reads the kept answer")

        await store.reload()
        _ = await store.figureReading(projectURL: project.url)
        XCTAssertEqual(made.count, 1, "the book is kept across a reload")
        XCTAssertEqual(made.first?.trustResolutions, 2, "a reload reads the book afresh")
    }

    func test_aBookWithNoRegistryStillAnswersAPictureLine() async throws {
        let (root, manifest) = try await fixture()
        var none = manifest
        none.figures = nil
        let book = loader()
        XCTAssertNil(book.card(forLinePath: "../research/shot.jpg", documentPath: docPath),
                     "no answer before a load")
        await book.load(manifest: none, projectURL: root)
        let shot = "../research/shot.jpg"
        XCTAssertEqual(book.card(forLinePath: shot, documentPath: docPath)?.kind, .image)
        XCTAssertEqual(book.imageURL(forLinePath: shot, documentPath: docPath)?
            .pathComponents.suffix(2), ["research", "shot.jpg"])
        XCTAssertEqual(plan(book, shot), .picture(try XCTUnwrap(
            book.imageURL(forLinePath: shot, documentPath: docPath))))
    }

    func test_anUnregisteredFiguresLine_isNotDownloadedYet() async throws {
        let (root, manifest) = try await fixture()
        var none = manifest
        none.figures = nil
        let book = loader()
        await book.load(manifest: none, projectURL: root)
        XCTAssertEqual(plan(book, "../figures/cash.csv"), .label(FigureCardText.notReady))
        await book.load(manifest: manifest, projectURL: root)
        XCTAssertEqual(plan(book, "../figures/x.csv"), .label(FigureCardText.notReady),
                       "with a registry too")
    }

    /// Retry re-reads the manifest: a figure registered on the Mac after the
    /// project opened on the phone has its card on the next load.
    func test_aFigureRegisteredAfterOpening_hasItsCardOnTheNextLoad() async throws {
        let (root, current) = try await fixture()
        try ProjectManifest.encodeForDisk(current)
            .write(to: root.appendingPathComponent(ProjectManifest.fileName))
        var opened = current
        opened.figures = nil
        let book = loader()
        await book.load(manifest: opened, projectURL: root)
        XCTAssertEqual(plan(book, "../figures/cash.csv"), .label(FigureCardText.notReady),
                       "the manifest captured at open does not know it")
        await book.loadCurrent(projectURL: root, opened: opened)
        guard case .table = plan(book, "../figures/cash.csv") else {
            return XCTFail("the re-read manifest registers the figure: its card")
        }
    }

    /// Trust that will not resolve leaves a registered figure with no card:
    /// not downloaded yet, never data and never "removed".
    func test_aTrustFailureLeavesARegisteredFigureWithNoCard() async throws {
        let (root, manifest) = try await fixture()
        let book = loader(resolveTrust: { _ in throw CocoaError(.fileReadUnknown) })
        await book.load(manifest: manifest, projectURL: root)
        XCTAssertNil(book.card(forLinePath: "../figures/cash.csv", documentPath: docPath))
        XCTAssertEqual(plan(book, "../figures/cash.csv"), .label(FigureCardText.notReady))
    }

    private func plan(_ book: PhoneFigureBook, _ path: String) -> FigureCardPlan {
        FigureCardPlan.plan(card: book.card(forLinePath: path, documentPath: docPath),
                            imageURL: book.imageURL(forLinePath: path, documentPath: docPath))
    }

    func test_imageURLResolvesInsideTheProjectOnly() async throws {
        let (root, manifest) = try await fixture(withImage: true)
        let book = loader()
        await book.load(manifest: manifest, projectURL: root)
        XCTAssertEqual(book.imageURL(forLinePath: "../figures/map.png", documentPath: docPath)?.lastPathComponent,
                       "map.png")
        XCTAssertNil(book.imageURL(forLinePath: "../figures/cash.csv", documentPath: docPath),
                     "a table figure has no picture")
        XCTAssertEqual(book.imageURL(forLinePath: "../research/shot.jpg", documentPath: docPath)?
            .pathComponents.suffix(2), ["research", "shot.jpg"])
        XCTAssertNil(book.imageURL(forLinePath: "../../outside.png", documentPath: docPath))
    }
}

private actor Counter {
    private(set) var value = 0
    func bump() { value += 1 }
}
