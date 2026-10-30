import XCTest
import AppKit
@testable import Maugham
@testable import MaughamCore

/// **Use in document** (report plan 6b Task 6, spec §4.1, ruling P-4): a CSV
/// or TSV added to Research is a Research table, and *Use in document* turns
/// a Research table, picture or PDF into a figure that records where it came
/// from. A working copy of a parked figure is not made into a new figure: it
/// goes to Task 8's return.
@MainActor
final class UseInDocumentTests: XCTestCase {

    private var projectURL: URL!
    /// Held for the test's length: `ProjectStore.documentStore` is weak.
    private var documentStore: DocumentStore?

    override func setUp() async throws {
        projectURL = TestTemp.root.appendingPathComponent("useindoc-\(UUID().uuidString)")
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
        documentStore = nil
        try? FileManager.default.removeItem(at: projectURL)
    }

    // MARK: - Fixture

    /// One chapter, bootstrapped, and a window over the book.
    private func openBook() async throws -> (DocumentStore, ProjectStore) {
        try "Words.\n".write(to: file("manuscript/a.md"), atomically: true, encoding: .utf8)
        let manifest = ProjectManifest(
            type: .novel, title: "T", author: "A", created: Date(), modified: Date(),
            structure: [StructureItem(id: "doc-a", title: "A", type: .document, path: "manuscript/a.md")],
            research: [])
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        try enc.encode(manifest).write(to: file(ProjectManifest.fileName))
        let store = try await DocumentStore.open(url: projectURL)
        let doc = try await Document.load(url: file("manuscript/a.md"), actor: .author, session: "boot", presenter: nil)
        await doc.close()
        let projectStore = try await ProjectStore.load(from: projectURL)
        projectStore.documentStore = store
        store.projectStore = projectStore
        documentStore = store
        return (store, projectStore)
    }

    private func file(_ relative: String) -> URL { projectURL.appendingPathComponent(relative) }

    /// A file outside the book, the way a writer drags one into Research.
    private func external(_ name: String, _ data: Data) throws -> URL {
        let folder = TestTemp.root.appendingPathComponent("outside-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    /// Figure `id`'s stream, read windowless.
    private func state(_ id: String) async throws -> FigureState {
        let doc = try await FigureDocument.load(
            figureId: id, projectURL: projectURL, actor: .author,
            session: "read", presenter: nil, documentStore: nil)
        let state = doc.state
        await doc.close()
        return state
    }

    private func rendered(_ record: FigureRecord) throws -> [[String]] {
        let text = try String(contentsOf: file(record.path), encoding: .utf8)  // adr-0018-ok: test reads the derived render to assert what was written
        return TableCSV.rows(text).rows
    }

    private let budgetCSV = """
        Item,Amount
        Rent,100
        Food,50
        Total,=SUM(B2:B3)
        Odd,=NOPE(1)
        Broken,=1+

        """

    // MARK: - Tables

    /// A CSV added to Research is a table; Use in document reads it into a new
    /// figure: `=SUM(B2:B3)` a formula (150), `=NOPE(1)` a formula showing
    /// `#NAME?`, `=1+` text holding itself and reported; the source recorded.
    func test_aResearchCSVBecomesATableFigure() async throws {
        let (store, projectStore) = try await openBook()
        let item = try await projectStore.addResearchAsset(
            parentId: nil, fromURL: try external("budget.csv", Data(budgetCSV.utf8)))
        XCTAssertEqual(item.kind, .table, "a CSV added to Research is a Research table")
        let researchFile = file(try XCTUnwrap(item.path))

        let result = try await projectStore.useInDocument(researchItemId: item.id, piece: "doc-a")
        let record = result.record

        XCTAssertEqual(record.kind, .table)
        XCTAssertEqual(record.name, "budget", "named from the item's title")
        XCTAssertEqual(record.piece, "doc-a")
        XCTAssertEqual(projectStore.manifest.figures?.map(\.id), [record.id])

        let s = try await state(record.id)
        XCTAssertEqual(s.table.rows.count, 6)
        XCTAssertEqual(s.table.columns.count, 2)
        XCTAssertEqual(s.table.headerRows, 1, "a text first row over numbers is a header")
        let at = { (r: Int, c: Int) in s.table[CellKey(row: s.table.rows[r], column: s.table.columns[c])]?.content }
        guard case .formula? = at(3, 1) else { return XCTFail("=SUM(B2:B3) is a formula") }
        guard case .formula? = at(4, 1) else { return XCTFail("=NOPE(1) stays a formula") }
        XCTAssertEqual(at(5, 1), .value(.text("=1+")), "an unparseable formula is text holding its =…")
        XCTAssertEqual(result.problems.map { [$0.row, $0.column] }, [[5, 1]],
                       "and it comes back as a problem")
        XCTAssertEqual(s.source, FigureSource(
            researchItemId: item.id, path: try XCTUnwrap(item.path),
            contentHash: try ContentHash.ofFile(researchFile)))

        await store.awaitOpenFigureRenderForTesting()
        let rows = try rendered(record)
        XCTAssertEqual(rows[3], ["Total", "150"])
        XCTAssertEqual(rows[4], ["Odd", "#NAME?"])
        XCTAssertEqual(rows[5], ["Broken", "=1+"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: researchFile.path),
                      "the Research copy stays where it was")
    }

    /// The name is the item's title, made vacant against the registry.
    func test_theNameIsDeDuplicatedAgainstTheRegistry() async throws {
        let (_, projectStore) = try await openBook()
        _ = try await projectStore.createFigure(kind: .table, name: "Budget", piece: nil)
        let item = try await projectStore.addResearchAsset(
            parentId: nil, fromURL: try external("budget.tsv", Data("a\tb\n1\t2\n".utf8)))
        XCTAssertEqual(item.kind, .table, "a TSV is a Research table too")
        let result = try await projectStore.useInDocument(researchItemId: item.id, piece: nil)
        let record = result.record
        XCTAssertEqual(record.name, "budget_2")
        XCTAssertEqual(result.problems, [])
        let s = try await state(record.id)
        XCTAssertEqual(s.table[CellKey(row: s.table.rows[1], column: s.table.columns[1])]?.content,
                       .value(.number(2)))
    }

    // MARK: - Label-safe names (report plan 8b Task 1)

    /// **A table's name is a label name** (`ManuscriptLabel.isValidName`), so
    /// its line's `{#tbl:…}` can be the record's name: a title with spaces and
    /// parentheses is folded as a picture's is, and a collision takes `_2`.
    func test_aTitleWithSpacesAndParenthesesGivesALabelName() async throws {
        let (_, projectStore) = try await openBook()
        let item = try await projectStore.addResearchAsset(
            parentId: nil, fromURL: try external("Q3 revenue (draft).csv", Data("a,b\n1,2\n".utf8)))
        XCTAssertEqual(item.title, "Q3 revenue (draft)", "precondition: the title a writer sees")
        let first = try await projectStore.useInDocument(researchItemId: item.id, piece: nil)
        XCTAssertEqual(first.record.name, "q3-revenue-draft")
        XCTAssertTrue(ManuscriptLabel.isValidName(first.record.name))
        XCTAssertEqual(first.record.path, "figures/q3-revenue-draft.csv")
        let second = try await projectStore.useInDocument(researchItemId: item.id, piece: nil)
        XCTAssertEqual(second.record.name, "q3-revenue-draft_2", "a collision is de-duplicated")
        XCTAssertTrue(ManuscriptLabel.isValidName(second.record.name))
    }

    /// **A name given is kept when it is a label name** (*Move into Figures*
    /// keeps its line's), folded when it is not, and de-duplicated either
    /// way; a picture keeps a given label name too, case and all.
    func test_aGivenNameIsKeptWhenItIsALabelName() async throws {
        let (_, projectStore) = try await openBook()
        let table = try await projectStore.addResearchAsset(
            parentId: nil, fromURL: try external("budget.csv", Data("a,b\n1,2\n".utf8)))
        let kept = try await projectStore.useInDocument(researchItemId: table.id, piece: nil, name: "Q3Revenue")
        XCTAssertEqual(kept.record.name, "Q3Revenue")
        let folded = try await projectStore.useInDocument(researchItemId: table.id, piece: nil, name: "Q3 (old)")
        XCTAssertEqual(folded.record.name, "q3-old")
        let again = try await projectStore.useInDocument(researchItemId: table.id, piece: nil, name: "q3revenue")
        XCTAssertEqual(again.record.name, "q3revenue_2", "taken in any case")

        let picture = try await projectStore.addResearchAsset(
            parentId: nil, fromURL: try external("Harbour Map.png", try TestImageBytes.png(seed: 4)))
        let map = try await projectStore.useInDocument(researchItemId: picture.id, piece: nil, name: "HarbourMap")
        XCTAssertEqual(map.record.name, "HarbourMap")
        XCTAssertEqual(map.record.path, "figures/HarbourMap.png")
    }

    // MARK: - A snapshot's source changed (report plan 8b Task 1, spec §4.1)

    /// **The card fill flags a figure whose Research source moved on**: an
    /// untouched source is not changed; an edit to its file is; a source whose
    /// file or item is gone is. A picture is flagged as a table is.
    func test_aSnapshotSourceEditOrDeletionFlipsChanged() async throws {
        let (store, projectStore) = try await openBook()
        let csv = try await projectStore.addResearchAsset(
            parentId: nil, fromURL: try external("budget.csv", Data("a,b\n1,2\n".utf8)))
        let png = try await projectStore.addResearchAsset(
            parentId: nil, fromURL: try external("map.png", try TestImageBytes.png(seed: 5)))
        let table = try await projectStore.useInDocument(researchItemId: csv.id, piece: nil).record
        let picture = try await projectStore.useInDocument(researchItemId: png.id, piece: nil).record

        let calmRead = await store.figureCardInputs()
        let calm = try XCTUnwrap(calmRead)
        XCTAssertEqual(calm.sourceChanged, [], "control: untouched sources are not changed")

        try Data("a,b\n1,3\n".utf8).write(to: file(try XCTUnwrap(csv.path)))
        let editedRead = await store.figureCardInputs()
        let edited = try XCTUnwrap(editedRead)
        XCTAssertEqual(edited.sourceChanged, [table.id], "the edited table's source, only")

        try FileManager.default.removeItem(at: file(try XCTUnwrap(png.path)))
        let fileGoneRead = await store.figureCardInputs()
        let fileGone = try XCTUnwrap(fileGoneRead)
        XCTAssertEqual(fileGone.sourceChanged, [table.id, picture.id], "a source file gone is changed")

        try Data("a,b\n1,2\n".utf8).write(to: file(try XCTUnwrap(csv.path)))
        let restoredRead = await store.figureCardInputs()
        let restored = try XCTUnwrap(restoredRead)
        XCTAssertEqual(restored.sourceChanged, [picture.id], "the same bytes again are not changed")

        projectStore.removeResearchItem(id: csv.id)
        let itemGoneRead = await store.figureCardInputs()
        let itemGone = try XCTUnwrap(itemGoneRead)
        XCTAssertEqual(itemGone.sourceChanged, [table.id, picture.id], "a source item gone is changed")
    }

    // MARK: - Pictures

    /// A picture in Research becomes an image figure through the image path,
    /// with its source's hash recorded on the create.
    func test_aPictureItemBecomesAnImageFigureWithItsSourceHash() async throws {
        let (store, projectStore) = try await openBook()
        let item = try await projectStore.addResearchAsset(
            parentId: nil, fromURL: try external("Harbour Map.png", try TestImageBytes.png(seed: 3)))
        let resolutionsBefore = store.figureTrustResolutions
        XCTAssertEqual(item.kind, .image)
        let researchFile = file(try XCTUnwrap(item.path))
        let hash = try ContentHash.ofFile(researchFile)

        let result = try await projectStore.useInDocument(researchItemId: item.id, piece: "doc-a")
        let record = result.record
        XCTAssertEqual(store.figureTrustResolutions, resolutionsBefore,
                       "a picture builds no workbook and resolves no trust (review M-2)")

        XCTAssertEqual(record.kind, .image)
        XCTAssertEqual(record.name, "harbour-map")
        XCTAssertEqual(record.path, "figures/harbour-map.png")
        let s = try await state(record.id)
        XCTAssertEqual(s.source, FigureSource(
            researchItemId: item.id, path: try XCTUnwrap(item.path), contentHash: hash))
        XCTAssertEqual(s.image?.contentHash, hash, "a PNG is copied as it is")
        XCTAssertEqual(result.problems, [])
    }

    /// A note can't be a figure: refused, nothing made.
    func test_aNoteIsRefused() async throws {
        let (_, projectStore) = try await openBook()
        let item = try await projectStore.addResearchAsset(
            parentId: nil, fromURL: try external("notes.md", Data("# Notes\n".utf8)))
        do {
            _ = try await projectStore.useInDocument(researchItemId: item.id, piece: nil)
            XCTFail("a note is not a figure")
        } catch let refused as UseInDocumentRefused {
            XCTAssertEqual(refused.reason, .notAFigure("notes"))
        }
        XCTAssertEqual(projectStore.manifest.figures ?? [], [])
    }

    // MARK: - A parked figure's working copy (Task 8's seam)

    /// An item whose sidecar names a PARKED figure goes to `bringBack` (Task
    /// 8): the copy, unchanged, resumes that figure and nothing is made. A
    /// sidecar naming a figure that is live, or one not in the book, makes a
    /// fresh figure.
    func test_aParkedFiguresWorkingCopyRoutesToTheReturn() async throws {
        let (store, projectStore) = try await openBook()
        let cash = try await projectStore.createFigure(kind: .table, name: "cash", piece: nil)
        let live = try await projectStore.createFigure(kind: .table, name: "live", piece: nil)
        let copy = try await projectStore.addResearchAsset(
            parentId: nil, fromURL: try external("cash.csv", Data("1,2\n".utf8)))
        let opStore = Document.makeLoadOpStore(projectURL: projectURL, presenter: nil)
        try await opStore.append(Op(
            opId: ULID.generate(), docId: cash.id, at: Date(),
            device: Document.loadIdentities[.author].deviceId, session: "park",
            kind: .figureParked, changes: [],
            figure: FigureOpPayload(
                parkedPath: try XCTUnwrap(copy.path),
                parkedHash: try ContentHash.ofFile(file(try XCTUnwrap(copy.path))), parkedItemId: copy.id)))
        _ = try await opStore.sealChain(docId: cash.id, actor: .author)
        store.figureCache.invalidate(figureId: cash.id)
        try ResearchTableSidecar.write(
            ResearchTableSidecar(figureId: cash.id, name: "cash"), forItem: copy.id, in: projectURL)

        let back = try await projectStore.useInDocument(researchItemId: copy.id, piece: nil, name: "renamed")
        XCTAssertEqual(back.record.id, cash.id, "a parked figure's copy goes back to its own log")
        XCTAssertEqual(back.record.name, "cash", "and keeps its own name, whatever name is given")
        XCTAssertEqual(projectStore.manifest.figures?.first?.name, "cash")
        let resumed = try await state(cash.id)
        XCTAssertNil(resumed.parked, "resumed")
        XCTAssertEqual(projectStore.manifest.figures?.map(\.id), [cash.id, live.id], "nothing was made")

        // Not parked, or not in the book: a fresh figure.
        let other = try await projectStore.addResearchAsset(
            parentId: nil, fromURL: try external("other.csv", Data("3,4\n".utf8)))
        try ResearchTableSidecar.write(ResearchTableSidecar(figureId: live.id), forItem: other.id, in: projectURL)
        let fresh = try await projectStore.useInDocument(researchItemId: other.id, piece: nil)
        XCTAssertEqual(fresh.record.name, "other")
        let stray = try await projectStore.addResearchAsset(
            parentId: nil, fromURL: try external("stray.csv", Data("5\n".utf8)))
        try ResearchTableSidecar.write(
            ResearchTableSidecar(figureId: "fig-gone0001"), forItem: stray.id, in: projectURL)
        let fresh2 = try await projectStore.useInDocument(researchItemId: stray.id, piece: nil)
        XCTAssertEqual(fresh2.record.name, "stray")
    }

    // MARK: - Review fixes (report plan 6b Task 6 review)

    private func setBookLanguage(_ tag: String) async throws {
        try await PublishConfigStore(projectURL: projectURL).save(
            PublishConfig(metadata: .init(title: "T", author: "A", language: tag)))
    }

    /// I-2: cells are read by the book's language — an en-GB book reads
    /// 03/04/2026 as 3 April, whatever the Mac's region.
    func test_datesAreReadByTheBooksLanguage() async throws {
        let (_, projectStore) = try await openBook()
        try await setBookLanguage("en-GB")
        let item = try await projectStore.addResearchAsset(
            parentId: nil, fromURL: try external("dates.csv", Data("When\n03/04/2026\n".utf8)))
        let result = try await projectStore.useInDocument(researchItemId: item.id, piece: nil)
        let s = try await state(result.record.id)
        XCTAssertEqual(s.table[CellKey(row: s.table.rows[1], column: s.table.columns[0])]?.content,
                       .value(.date(try XCTUnwrap(DateSerial.serial(year: 2026, month: 4, day: 3)))))
    }

    /// M-4: a European book's TSV reads decimal commas.
    func test_aEuropeanTSVReadsDecimalCommas() async throws {
        let (_, projectStore) = try await openBook()
        try await setBookLanguage("de-DE")
        let item = try await projectStore.addResearchAsset(
            parentId: nil, fromURL: try external("kosten.tsv", Data("Posten\tBetrag\nTee\t1,5\n".utf8)))
        let result = try await projectStore.useInDocument(researchItemId: item.id, piece: nil)
        let s = try await state(result.record.id)
        XCTAssertEqual(s.table[CellKey(row: s.table.rows[1], column: s.table.columns[1])]?.content,
                       .value(.number(1.5)))
    }

    /// M-1: a sidecar written for exactly this CSV lays its settings on; one
    /// written for other bytes (the file edited elsewhere since) does not.
    func test_aSidecarsSettingsApplyOnlyToTheBytesTheyDescribe() async throws {
        let (_, projectStore) = try await openBook()
        let csv = Data("1,2\n3,4\n".utf8)
        let sidecar = { (hash: String) in ResearchTableSidecar(
            contentHash: hash, headerRows: 1, totalRow: true,
            formats: [.init(row: 1, column: 1, format: CellFormat(number: .percent(decimals: 1)))],
            columnWidths: [nil, 90]) }

        let matching = try await projectStore.addResearchAsset(parentId: nil, fromURL: try external("same.csv", csv))
        try ResearchTableSidecar.write(sidecar(ContentHash.of(csv)), forItem: matching.id, in: projectURL)
        let applied = try await state(
            try await projectStore.useInDocument(researchItemId: matching.id, piece: nil).record.id)
        XCTAssertEqual(applied.table.headerRows, 1)
        XCTAssertTrue(applied.table.hasTotalRow)
        XCTAssertEqual(applied.table[CellKey(row: applied.table.rows[1], column: applied.table.columns[1])]?.format,
                       CellFormat(number: .percent(decimals: 1)))
        XCTAssertEqual(applied.table.columnWidths, [applied.table.columns[1]: 90])

        let edited = try await projectStore.addResearchAsset(parentId: nil, fromURL: try external("edited.csv", csv))
        try ResearchTableSidecar.write(sidecar("ffffffffffffffff"), forItem: edited.id, in: projectURL)
        let plain = try await state(
            try await projectStore.useInDocument(researchItemId: edited.id, piece: nil).record.id)
        XCTAssertEqual(plain.table.headerRows, 0)
        XCTAssertFalse(plain.table.hasTotalRow)
        XCTAssertEqual(plain.table[CellKey(row: plain.table.rows[1], column: plain.table.columns[1])]?.format,
                       CellFormat())
        XCTAssertEqual(plain.table.columnWidths, [:])
    }

    /// M-3: a CSV above the ceiling is refused with the cell count, and nothing is made.
    func test_aTableAboveTheCeilingIsRefused() async throws {
        let (_, projectStore) = try await openBook()
        let row = Array(repeating: "1", count: 101).joined(separator: ",")
        let text = Array(repeating: row, count: 100).joined(separator: "\n") + "\n"   // 10,100 cells
        let item = try await projectStore.addResearchAsset(
            parentId: nil, fromURL: try external("huge.csv", Data(text.utf8)))
        do {
            _ = try await projectStore.useInDocument(researchItemId: item.id, piece: nil)
            XCTFail("a table above the ceiling is refused")
        } catch let refused as UseInDocumentRefused {
            XCTAssertEqual(refused.reason, .tooLarge(cells: 10_100))
            XCTAssertEqual(refused.localizedDescription,
                           "This table is too large to use as a figure (10100 cells; the limit is 10,000).")
        }
        XCTAssertEqual(projectStore.manifest.figures ?? [], [])
    }

    // MARK: - Final review M-5: a parked copy, used by someone who may not edit it

    /// **Use in document on a parked figure's copy by a Mac that may not edit
    /// that figure makes a new, independent figure** (final review M-5,
    /// Denver's ruling): the parked figure stays parked and untouched, the
    /// new figure holds the copy's data and none of its id, and the sidecar's
    /// formats apply because they were written for these bytes. Once this
    /// Mac may edit the figure again (Edit Anyway), the same copy brings it
    /// back.
    func test_aParkedCopyUsedByAMacThatMayNotEditTheFigureMakesANewFigure() async throws {
        let (store, projectStore) = try await openBook()
        let cash = try await projectStore.createFigure(kind: .table, name: "cash", piece: "doc-a", rows: 2, columns: 1)
        let host = try await store.openFigure(figureId: cash.id)
        try await host.setCell(Cell(content: .value(.number(5)), format: CellFormat(number: .percent(decimals: 1))),
                               at: CellKey(row: host.state.table.rows[1], column: host.state.table.columns[0]))
        await store.closeFigure(figureId: cash.id)
        let copy = try await projectStore.sendToResearch(figureId: cash.id, scope: .shared)
        let parkedOps = try OpLogStore.loadSyncMerged(forDocId: cash.id, in: projectURL, facts: .empty).count
        let sam = LocalIdentities.softwareForTesting()
        _ = try await store.admit(
            device: sam.author.fingerprint, label: "Sam", ownName: "Sam’s Mac",
            permit: .author(.pieces(["doc-a"])))
        await store.postureSettled()
        XCTAssertFalse(store.posture(forDocId: cash.id).allows(.editFigure), "precondition: this Mac yields on A")

        let result = try await projectStore.useInDocument(researchItemId: copy.id, piece: nil)

        XCTAssertNotEqual(result.record.id, cash.id, "a new figure, not the parked one")
        XCTAssertEqual(result.record.name, "cash_2")
        XCTAssertEqual(projectStore.manifest.figures?.count, 2)
        let made = try await state(result.record.id)
        XCTAssertEqual(made.source?.researchItemId, copy.id)
        let five = made.table[CellKey(row: made.table.rows[1], column: made.table.columns[0])]
        XCTAssertEqual(five?.content, .value(.number(5)), "the copy's data")
        XCTAssertEqual(five?.format, CellFormat(number: .percent(decimals: 1)), "the sidecar's formats, for these bytes")
        let still = try await state(cash.id)
        XCTAssertNotNil(still.parked, "the parked figure stays parked")
        XCTAssertEqual(try OpLogStore.loadSyncMerged(forDocId: cash.id, in: projectURL, facts: .empty).count,
                       parkedOps, "and nothing was appended to it")

        store.overrideYield(docId: "doc-a")
        let back = try await projectStore.useInDocument(researchItemId: copy.id, piece: nil)
        XCTAssertEqual(back.record.id, cash.id, "a Mac that may edit it brings it back")
    }
}
