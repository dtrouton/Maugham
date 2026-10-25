import XCTest
import AppKit
@testable import Maugham
@testable import MaughamCore

/// **Research pins on the Mac** (report plan 6b Task 9, spec §4.3, Denver's
/// ruling R-D2, ruling P-8). A formula reading a Research table pins what it
/// read; a figure reading a figure parked in Research keeps its parked
/// values. When the source changes the reader says so, Compare shows old
/// beside new, and Refresh — behind the READER's own door — writes the new
/// pins into that figure only, as one ⌘Z.
@MainActor
final class FigurePinTests: XCTestCase {

    private var projectURL: URL!
    private static let pieceB = "doc-b"

    override func setUp() async throws {
        projectURL = TestTemp.root.appendingPathComponent("figurepins-\(UUID().uuidString)")
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

    // MARK: - Fixture

    /// Chapters A and B, each bootstrapped by this Mac's hand, and a window.
    private func openBook() async throws -> (DocumentStore, ProjectStore) {
        for slug in ["a", "b"] {
            try "Words.\n".write(to: file("manuscript/\(slug).md"), atomically: true, encoding: .utf8)
        }
        let manifest = ProjectManifest(
            type: .novel, title: "T", author: "A", created: Date(), modified: Date(),
            structure: ["a", "b"].map {
                StructureItem(id: "doc-\($0)", title: $0.uppercased(), type: .document,
                              path: "manuscript/\($0).md")
            },
            research: [])
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        try enc.encode(manifest).write(to: file(ProjectManifest.fileName))
        let store = try await DocumentStore.open(url: projectURL)
        for slug in ["a", "b"] {
            let doc = try await Document.load(
                url: file("manuscript/\(slug).md"), actor: .author, session: "boot", presenter: nil)
            await doc.close()
        }
        let projectStore = try await ProjectStore.load(from: projectURL)
        projectStore.documentStore = store
        store.projectStore = projectStore
        return (store, projectStore)
    }

    private func file(_ relative: String) -> URL { projectURL.appendingPathComponent(relative) }

    /// A file outside the book, the way a writer drags one into Research.
    private func external(_ name: String, _ text: String) throws -> URL {
        let folder = TestTemp.root.appendingPathComponent("outside-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        return url
    }

    /// `relative` rewritten on disk, as Excel or another device would.
    private func rewrite(_ relative: String, _ text: String) throws {
        try Data(text.utf8).write(to: file(relative))
    }

    private func rendered(_ record: FigureRecord) throws -> [[String]] {
        let text = try String(contentsOf: file(record.path), encoding: .utf8)  // adr-0018-ok: test reads the derived render to assert what was written
        return TableCSV.rows(text).rows
    }

    /// Every op in every file of the figure's stream, seals excluded.
    private func ops(of figureId: String) throws -> [Op] {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = JSONLAppendStore<Op>.dateDecoding
        return try OpLogStore.opLogFileURLs(forDocId: figureId, in: projectURL).flatMap { url in
            try Data(contentsOf: url)
                .split(separator: UInt8(0x0A), omittingEmptySubsequences: true)
                .compactMap { line -> Op? in
                    let data = Data(line)
                    return OpLogChain.isSealLine(data) ? nil : try? dec.decode(Op.self, from: data)
                }
        }.sorted { $0.opId < $1.opId }
    }

    private let modelCSV = "Year,Revenue\n2025,10\n2026,20\n"

    /// A Research table `model` and a figure `summary` (in `piece`) whose A1
    /// reads `research:model!B2*2`, entered through its open host.
    private func summaryReadingModel(
        _ store: DocumentStore, _ projectStore: ProjectStore, piece: String? = nil
    ) async throws -> (item: ResearchItem, summary: FigureRecord, host: FigureDocument, a1: CellKey) {
        let item = try await projectStore.addResearchAsset(parentId: nil, fromURL: try external("model.csv", modelCSV))
        XCTAssertEqual(item.kind, .table, "precondition: a Research table")
        let summary = try await projectStore.createFigure(kind: .table, name: "summary", piece: piece)
        let host = try await store.openFigure(figureId: summary.id)
        let a1 = CellKey(row: host.state.table.rows[0], column: host.state.table.columns[0])
        let names = FormulaNames(research: [(item.id, item.title)])
        guard case .success(let f) = FormulaParser.parse("research:model!B2*2", in: host.state.table, names: names)
        else { throw FigureEditInvalid(reason: "the formula did not parse") }
        try await host.setCell(Cell(content: .formula(f)), at: a1)
        await store.awaitOpenFigureRenderForTesting()
        return (item, summary, host, a1)
    }

    // MARK: - A Research table

    /// **Entering the formula takes its pin; the CSV edited on disk says
    /// changed; Compare lists old and new; Refresh writes the new pin and the
    /// render follows; ⌘Z puts the old pin back.**
    func test_aResearchCSVEditedOnDisk_saysChanged_comparesAndRefreshes_andUndoRestoresTheOldPin() async throws {
        let (store, projectStore) = try await openBook()
        let (item, summary, host, a1) = try await summaryReadingModel(store, projectStore)
        let path = try XCTUnwrap(item.path)
        let h1 = try ContentHash.ofFile(file(path))

        let entry = try XCTUnwrap(host.state.pins[a1]?.first, "entering the formula took a pin")
        XCTAssertEqual(entry.research, item.id)
        XCTAssertEqual([entry.row, entry.column], [1, 1])
        XCTAssertEqual(entry.value, .number(10))
        XCTAssertEqual(entry.sourceHash, h1)
        XCTAssertEqual(try rendered(summary).first?.first, "20", "the render reads the pin")
        let status0 = await host.pinStatus()
        XCTAssertEqual(status0, [item.id: .current])

        try rewrite(path, "Year,Revenue\n2025,15\n2026,20\n")
        let h2 = try ContentHash.ofFile(file(path))
        let status1 = await host.pinStatus()
        XCTAssertEqual(status1, [item.id: .sourceChanged(old: h1, new: h2)])
        let compared = await host.comparePins()
        XCTAssertEqual(compared, [PinComparison(
            cell: a1, read: PinRead(source: item.id, row: 1, column: 1), old: .number(10), new: .number(15))])
        XCTAssertEqual(try rendered(summary).first?.first, "20", "nothing changes until a refresh")

        let before = try ops(of: summary.id).count
        let um = UndoManager()
        try await host.refreshPins(undoManager: um)
        await store.awaitOpenFigureRenderForTesting()
        let written = try ops(of: summary.id).dropFirst(before)
        XCTAssertEqual(written.map(\.kind), [.figurePinSet], "one pin, into the reading figure only")
        XCTAssertEqual(written.first?.figure?.priorPin, entry, "carrying the pin it replaced (ruling P-8)")
        XCTAssertEqual(host.state.pins[a1]?.first?.value, .number(15))
        XCTAssertEqual(host.state.pins[a1]?.first?.sourceHash, h2)
        XCTAssertEqual(try rendered(summary).first?.first, "30")
        let status2 = await host.pinStatus()
        XCTAssertEqual(status2, [item.id: .current])

        // A re-read of the stream (another device's echo) must not trip the
        // ⌘Z's drift guard: the pins read back equal the ones written.
        try await host.reload()
        XCTAssertTrue(um.canUndo)
        um.undo()
        await host.awaitPendingUndoWork()
        await store.awaitOpenFigureRenderForTesting()
        XCTAssertEqual(host.state.pins[a1], [entry], "⌘Z restores the old pin")
        XCTAssertEqual(try rendered(summary).first?.first, "20")
        let status3 = await host.pinStatus()
        XCTAssertEqual(status3, [item.id: .sourceChanged(old: h1, new: h2)])
        um.redo()
        await host.awaitPendingUndoWork()
        XCTAssertEqual(host.state.pins[a1]?.first?.value, .number(15), "redo refreshes again")
        await store.closeFigure(figureId: summary.id)
    }

    /// **A reader whose figure this Mac may not edit refuses the refresh**:
    /// the figure belongs to piece B, which this Mac yields to Sam. Nothing
    /// is appended to it (R-D2: refresh needs the reading figure's door).
    func test_aRefreshOfAFigureThisMacMayNotEditIsRefused() async throws {
        let (store, projectStore) = try await openBook()
        let (item, summary, host, _) = try await summaryReadingModel(store, projectStore, piece: Self.pieceB)
        try rewrite(try XCTUnwrap(item.path), "Year,Revenue\n2025,15\n2026,20\n")
        let sam = LocalIdentities.softwareForTesting()
        _ = try await store.admit(
            device: sam.author.fingerprint, label: "Sam", ownName: "Sam’s Mac",
            permit: .author(.pieces([Self.pieceB])))
        await store.postureSettled()
        let before = try ops(of: summary.id).count

        do {
            try await host.refreshPins()
            XCTFail("a refresh of a yielded piece's figure was not refused")
        } catch let refused as FigureEditRefused {
            XCTAssertEqual(refused.site, "refreshPins")
        }
        XCTAssertEqual(try ops(of: summary.id).count, before, "nothing was appended")
        await store.closeFigure(figureId: summary.id)
    }

    // MARK: - A figure parked in Research (R-D2)

    /// **A parked figure's working copy edited**: the figure reading it says
    /// changed against the park's hash, Compare shows the parked value beside
    /// the copy's, and Refresh pins the copy's value at the cell's position in
    /// the parked table. The copy then deleted: missing, the value kept.
    func test_aParkedFiguresCopyEdited_readerSaysChanged_refreshReadsTheCopy_andADeletedCopyIsMissing() async throws {
        let (store, projectStore) = try await openBook()
        let cash = try await projectStore.createFigure(kind: .table, name: "cash", piece: nil)
        let total = try await projectStore.createFigure(kind: .table, name: "total", piece: nil)
        let cashDoc = try await store.openFigure(figureId: cash.id)
        let a2 = CellKey(row: cashDoc.state.table.rows[1], column: cashDoc.state.table.columns[0])
        try await cashDoc.setCell(Cell(content: .value(.number(5))), at: a2)
        let totalDoc = try await store.openFigure(figureId: total.id)
        let t1 = CellKey(row: totalDoc.state.table.rows[0], column: totalDoc.state.table.columns[0])
        let names = FormulaNames(figures: [.init(id: cash.id, name: "cash", table: cashDoc.state.table)])
        guard case .success(let f) = FormulaParser.parse("cash!A2*2", in: totalDoc.state.table, names: names)
        else { throw FigureEditInvalid(reason: "the formula did not parse") }
        try await totalDoc.setCell(Cell(content: .formula(f)), at: t1)
        await store.closeFigure(figureId: cash.id)
        XCTAssertNil(totalDoc.state.pins[t1], "a ref to a live figure takes no pin")

        let copy = try await projectStore.sendToResearch(figureId: cash.id, scope: .shared)
        await store.awaitOpenFigureRenderForTesting()
        let path = try XCTUnwrap(copy.path)
        let parkedHash = try ContentHash.ofFile(file(path))
        XCTAssertEqual(try rendered(total).first?.first, "10", "the reader keeps the parked value")
        let status0 = await totalDoc.pinStatus()
        XCTAssertEqual(status0, [cash.id: .current])

        XCTAssertEqual(try String(contentsOf: file(path), encoding: .utf8), ",,\n5,,\n,,\n", "precondition: the copy")  // adr-0018-ok: test reads the Research working copy it is about to edit
        try rewrite(path, ",,\n7,,\n,,\n")
        let edited = try ContentHash.ofFile(file(path))
        let status1 = await totalDoc.pinStatus()
        XCTAssertEqual(status1, [cash.id: .sourceChanged(old: parkedHash, new: edited)])
        let compared = await totalDoc.comparePins()
        XCTAssertEqual(compared, [PinComparison(
            cell: t1, read: PinRead(source: cash.id, row: 1, column: 0), old: .number(5), new: .number(7))])

        try await totalDoc.refreshPins()
        await store.awaitOpenFigureRenderForTesting()
        let pin = try XCTUnwrap(totalDoc.state.pins[t1]?.first)
        XCTAssertEqual([pin.research, "\(pin.row)", "\(pin.column)"], [cash.id, "1", "0"])
        XCTAssertEqual(pin.value, .number(7))
        XCTAssertEqual(pin.sourceHash, edited)
        XCTAssertEqual(try rendered(total).first?.first, "14", "the reader reads the copy's value")
        let parked = try await FigureDocument.load(
            figureId: cash.id, projectURL: projectURL, actor: .author, session: "r",
            presenter: nil, documentStore: nil)
        XCTAssertNotNil(parked.state.parked, "the parked figure itself was not written")
        await parked.close()

        try FileManager.default.removeItem(at: file(path))
        let status2 = await totalDoc.pinStatus()
        XCTAssertEqual(status2, [cash.id: .sourceMissing])
        let before = try ops(of: total.id).count
        try await totalDoc.refreshPins()
        XCTAssertEqual(try ops(of: total.id).count, before, "a missing copy is not read, nothing written")
        await store.renderFigures(changed: [total.id])
        XCTAssertEqual(try rendered(total).first?.first, "14", "the kept value stands")
        await store.closeFigure(figureId: total.id)
    }
}
