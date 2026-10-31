import XCTest
@testable import MaughamCore
@testable import Maugham

/// Report plan 9e-1 Task 3: a table figure's text cells are translated through
/// `TranslationWritePipeline.performCells` — the same door, forms and single
/// append as a paragraph batch, over the figure's op-log state.
@MainActor
final class FigureCellTranslationWriteTests: XCTestCase {

    private var projectURL: URL!

    override func setUp() async throws {
        projectURL = TestTemp.root.appendingPathComponent("cellwrite-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: projectURL.appendingPathComponent("manuscript"), withIntermediateDirectories: true)
        let identities = LocalIdentities.softwareForTesting()
        Document.localIdentitiesForTesting = identities
        Document.deviceStateForTesting = OpLogDeviceState(
            fileURL: projectURL.appendingPathComponent("op-log-state.json"))
        Document.registryCacheForTesting = RegistryCache(
            fileURL: projectURL.appendingPathComponent("registry-cache.json"),
            identity: identities.author.fingerprint)
        Document.admissionMemoryForTesting = AdmissionMemory(
            fileURL: projectURL.appendingPathComponent("admission-memory.json"),
            identity: identities.author.fingerprint)
    }

    override func tearDown() async throws {
        Document.localIdentitiesForTesting = nil
        Document.deviceStateForTesting = nil
        Document.registryCacheForTesting = nil
        Document.admissionMemoryForTesting = nil
        try? FileManager.default.removeItem(at: projectURL)
    }

    private func file(_ relative: String) -> URL { projectURL.appendingPathComponent(relative) }

    private struct Book {
        let ds: DocumentStore
        let store: ProjectStore
        let figureId: String
        let table: FigureTable
    }

    /// One chapter and a table `cash`: Item | Amount, Rent | 100, Food | 200.
    private func openBook() async throws -> Book {
        try "Opening.\n".write(to: file("manuscript/a.md"), atomically: true, encoding: .utf8)
        let manifest = ProjectManifest(
            type: .novel, title: "T", author: "A", created: Date(), modified: Date(),
            structure: [StructureItem(id: "doc-a", title: "Chapter A", type: .document,
                                      path: "manuscript/a.md")],
            research: [])
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        try enc.encode(manifest).write(to: file(ProjectManifest.fileName))
        let ds = try await DocumentStore.open(url: projectURL)
        let doc = try await Document.load(
            url: file("manuscript/a.md"), actor: .author, session: "boot", presenter: nil)
        await doc.close()
        let store = try await ProjectStore.load(from: projectURL)
        store.documentStore = ds
        ds.projectStore = store

        var table = FigureTable(rows: 3, columns: 2)
        table.headerRows = 1
        let texts = [["Item", "Amount"], ["Rent", nil], ["Food", nil]]
        for (r, row) in texts.enumerated() {
            for (c, text) in row.enumerated() {
                let key = CellKey(row: table.rows[r], column: table.columns[c])
                if let text {
                    table.setCell(Cell(content: .value(.text(text))), at: key)
                } else {
                    table.setCell(Cell(content: .value(.number(Double(r * 100)))), at: key)
                }
            }
        }
        let record = try await store.createFigure(kind: .table, name: "cash", piece: nil, table: table)
        await ds.awaitOpenFigureRenderForTesting()
        let snapshot = await store.publishFigures()
        let folded = try XCTUnwrap(snapshot.states[record.id]?.table, "premise: the figure folds")
        return Book(ds: ds, store: store, figureId: record.id, table: folded)
    }

    private func key(_ table: FigureTable, _ row: Int, _ column: Int) -> CellKey {
        CellKey(row: table.rows[row], column: table.columns[column])
    }

    @discardableResult
    private func write(_ book: Book, _ entries: [TranslationWritePipeline.CellEntry],
                       table: FigureTable? = nil) async throws -> [String] {
        try await TranslationWritePipeline.performCells(
            entries: entries, language: "es", figureId: book.figureId,
            table: table ?? book.table, projectURL: projectURL, actor: .translator,
            identities: try XCTUnwrap(Document.localIdentitiesForTesting),
            deviceState: try XCTUnwrap(Document.deviceStateForTesting))
    }

    private func records(_ book: Book) throws -> [TranslationRecord] {
        try TranslationStore.loadMerged(
            forDocId: book.figureId, language: "es", in: projectURL,
            identities: try XCTUnwrap(Document.localIdentitiesForTesting),
            state: try XCTUnwrap(Document.deviceStateForTesting))
    }

    private func translationFiles(_ book: Book) -> [URL] {
        TranslationStore.fileURLs(forDocId: book.figureId, language: "es", in: projectURL)
    }

    // MARK: - Tests

    /// **A text cell's translation is filed under the figure, keyed by its row
    /// and column ids, hashed against the source label** — and it derives fresh.
    func test_aTextCellsTranslationIsWrittenUnderTheFigureAndReadsFresh() async throws {
        let book = try await openBook()
        let a1 = key(book.table, 0, 0), a2 = key(book.table, 1, 0)

        var announced: (figure: String?, language: String?, document: String?)?
        let token = MaughamEvent.observe(
            .maughamTranslationDidUpdate,
            context: {
                EventReceiverContext(
                    kind: .project(id: ProjectIdentifier.id(for: self.projectURL)),
                    isWindowLive: true, isWindowKey: false)
            },
            handler: {
                announced = ($0.userInfo?["figure_id"] as? String,
                             $0.userInfo?["language"] as? String,
                             $0.userInfo?["document_id"] as? String)
            })
        defer { NotificationCenter.default.removeObserver(token) }

        let warnings = try await write(book, [
            .init(key: a1, text: "Concepto"),
            .init(key: a2, verbatim: true),
        ])
        XCTAssertTrue(warnings.isEmpty, "\(warnings)")

        let stored = try records(book)
        XCTAssertEqual(Set(stored.map(\.paragraphId)), [
            FigureCellTranslationKey.paragraphId(for: a1),
            FigureCellTranslationKey.paragraphId(for: a2),
        ], "ids stored, never A1")
        let byId = Dictionary(uniqueKeysWithValues: stored.map { ($0.paragraphId, $0) })
        XCTAssertEqual(byId[FigureCellTranslationKey.paragraphId(for: a1)]?.sourceHash,
                       TranslationHash.hash("Item"), "hashed against the source label")
        XCTAssertEqual(byId[FigureCellTranslationKey.paragraphId(for: a2)]?.text, "Rent",
                       "verbatim copies the current source")

        let derived = FigureTranslationDeriver.derive(records: stored, table: book.table, language: "es")
        XCTAssertEqual(derived.freshLabels[a1], "Concepto")
        XCTAssertEqual(derived.freshCount, 2)

        XCTAssertEqual(announced?.figure, book.figureId, "the update names the figure")
        XCTAssertEqual(announced?.language, "es")
        XCTAssertNil(announced?.document, "never mistaken for a manuscript document")
    }

    /// **A number cell is not a text cell** — refused by its A1 address, and
    /// the whole batch writes nothing.
    func test_aNonTextCellIsRefusedAndNothingIsWritten() async throws {
        let book = try await openBook()
        do {
            try await write(book, [
                .init(key: key(book.table, 0, 0), text: "Concepto"),
                .init(key: key(book.table, 1, 1), text: "cien"),
            ])
            XCTFail("a number cell was translated")
        } catch MCPError.invalidArgument(let message) {
            XCTAssertTrue(message.contains("not text cells: B2"), message)
        }
        XCTAssertTrue(translationFiles(book).isEmpty, "all or nothing")
    }

    /// **An id the table does not hold is refused as unknown** — but a
    /// `delete` naming it is exempt, so a cell orphan can be purged.
    func test_anUnknownCellIsRefusedButItsDeleteIsAccepted() async throws {
        let book = try await openBook()
        let gone = CellKey(row: RowID("zzzzzzzz"), column: book.table.columns[0])
        do {
            try await write(book, [.init(key: gone, text: "Fantasma")])
            XCTFail("an unknown cell was translated")
        } catch MCPError.invalidArgument(let message) {
            XCTAssertTrue(message.contains("unknown cells"), message)
            XCTAssertTrue(message.contains(FigureCellTranslationKey.paragraphId(for: gone)),
                          "a cell with no address is named by its key: \(message)")
        }
        XCTAssertTrue(translationFiles(book).isEmpty)

        // A delete of a number cell and of the unknown cell is accepted beside
        // a real translation.
        try await write(book, [
            .init(key: key(book.table, 0, 0), text: "Concepto"),
            .init(key: gone, delete: true),
            .init(key: key(book.table, 1, 1), delete: true),
        ])
        let stored = try records(book)
        XCTAssertEqual(stored.count, 3, "two tombstones and a translation, in one batch")
        XCTAssertEqual(Array(TranslationStore.latestByParagraph(stored).keys),
                       [FigureCellTranslationKey.paragraphId(for: key(book.table, 0, 0))],
                       "the tombstones leave only the translation")
    }

    /// **The delete form tombstones a cell's translation**: it reads missing.
    func test_theDeleteFormTombstonesACellsTranslation() async throws {
        let book = try await openBook()
        let a1 = key(book.table, 0, 0)
        try await write(book, [.init(key: a1, text: "Concepto")])
        try await write(book, [.init(key: a1, delete: true)])
        let derived = FigureTranslationDeriver.derive(
            records: try records(book), table: book.table, language: "es")
        XCTAssertEqual(derived.entries.first { $0.key == a1 }?.status, .missing)
        XCTAssertTrue(derived.orphans.isEmpty)
    }

    /// **The pipeline's shared rules hold for cells**: one form per entry, no
    /// repeated cell, an equals-source reminder by A1.
    func test_theSharedRulesHoldForCells() async throws {
        let book = try await openBook()
        let a1 = key(book.table, 0, 0)
        do {
            try await write(book, [.init(key: a1, text: "Concepto", verbatim: true)])
            XCTFail("two forms were accepted")
        } catch MCPError.invalidArgument(let message) {
            XCTAssertTrue(message.contains("entry for cell A1 must supply exactly one"), message)
        }
        do {
            try await write(book, [.init(key: a1, text: "Uno"), .init(key: a1, text: "Dos")])
            XCTFail("a repeated cell was accepted")
        } catch MCPError.invalidArgument(let message) {
            XCTAssertEqual(message, "duplicate cells in batch: A1")
        }
        XCTAssertTrue(translationFiles(book).isEmpty)
        let warnings = try await write(book, [.init(key: a1, text: "Item")])
        XCTAssertEqual(warnings, ["A1: translated text equals source — mark verbatim: true if deliberate"])
    }
}
