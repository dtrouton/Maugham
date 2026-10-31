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
