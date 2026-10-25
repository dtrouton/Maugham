import XCTest
import AppKit
@testable import Maugham
@testable import MaughamCore

/// **What a Collection piece's promotion carries of the book's figures, and
/// the streams that re-create them in the staged project** (report plan 6c
/// Task 4, rulings Q-4 to Q-6; Denver 2026-10-25: promotion re-creates, the
/// history stays in the Collection). Task 5 wires both into
/// `promotePieceToProject`.
@MainActor
final class PromoteFigureCarryTests: XCTestCase {

    private var root: URL!

    override func setUp() async throws {
        root = TestTemp.root.appendingPathComponent("promote-carry-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let identities = LocalIdentities.softwareForTesting()
        Document.localIdentitiesForTesting = identities
        Document.deviceStateForTesting = OpLogDeviceState(
            fileURL: root.appendingPathComponent("op-log-state.json"))
        Document.registryCacheForTesting = RegistryCache(
            fileURL: root.appendingPathComponent("registry-cache.json"),
            identity: identities.author.fingerprint)
        Document.admissionMemoryForTesting = AdmissionMemory(
            fileURL: root.appendingPathComponent("admission-memory.json"),
            identity: identities.author.fingerprint)
    }

    override func tearDown() async throws {
        Document.localIdentitiesForTesting = nil
        Document.deviceStateForTesting = nil
        Document.registryCacheForTesting = nil
        Document.admissionMemoryForTesting = nil
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Fixture

    /// A Collection holding one loose piece whose text says `text`, with a
    /// window over it.
    private func openCollection(text: String) async throws -> (ProjectStore, DocumentStore, StructureItem) {
        let collection = try await ProjectFactory.createCollectionProject(named: "Anthology", in: root)
        let projectStore = try await ProjectStore.load(from: collection)
        let piece = try await projectStore.addLoosePiece(title: "Story A", format: .markdown)
        let store = try await DocumentStore.open(url: collection)
        projectStore.documentStore = store
        store.projectStore = projectStore
        let doc = try await Document.load(
            url: collection.appendingPathComponent(try XCTUnwrap(piece.path)),
            actor: .author, session: "boot", presenter: nil)
        doc.setFullText(text)
        await doc.close()
        return (projectStore, store, piece)
    }

    private func png(_ name: String) throws -> URL {
        let dir = root.appendingPathComponent("png-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let image = NSImage(size: NSSize(width: 4, height: 4))
        image.lockFocus()
        NSColor.blue.setFill()
        NSRect(x: 0, y: 0, width: 4, height: 4).fill()
        image.unlockFocus()
        let url = dir.appendingPathComponent(name)
        try ImagePasteHandler.encodePNG(image).write(to: url)
        return url
    }

    /// Every op in every file of `figureId`'s stream under `projectURL`, and
    /// whether each file holds a seal.
    private func stream(_ figureId: String, in projectURL: URL) throws -> (ops: [Op], sealed: [Bool]) {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = JSONLAppendStore<Op>.dateDecoding
        var ops: [Op] = []
        var sealed: [Bool] = []
        for url in try OpLogStore.opLogFileURLs(forDocId: figureId, in: projectURL) {
            let lines = try Data(contentsOf: url).split(separator: UInt8(0x0A), omittingEmptySubsequences: true)
            sealed.append(lines.contains { OpLogChain.isSealLine(Data($0)) })
            ops += lines.compactMap { line -> Op? in
                let data = Data(line)
                return OpLogChain.isSealLine(data) ? nil : try? dec.decode(Op.self, from: data)
            }
        }
        return (ops.sorted { $0.opId < $1.opId }, sealed)
    }

    /// Figure `id`'s state as a host in the project at `projectURL` reads it.
    private func state(_ id: String, in projectURL: URL) async throws -> FigureState {
        let doc = try await FigureDocument.load(
            figureId: id, projectURL: projectURL, actor: .author,
            session: "read", presenter: nil, documentStore: nil)
        let state = doc.state
        await doc.close()
        return state
    }

    // MARK: - Tests

    /// Review Focus 3's carry: the text cites a whole-book table whose
    /// formula reads a second whole-book table and a Research item that
    /// stays behind. Both tables are copied (the second only through the
    /// first's formula), the piece's own table, picture and parked table
    /// move, an unnamed whole-book table stays, and the Research read is
    /// listed. Each carried stream is re-created in the staged root by this
    /// Mac's author, sealed, keeping its ids, folding to the state it had —
    /// the parked one parked again — and the picture is copied. The
    /// Collection is unchanged.
    func test_theCarry_andTheReCreatedStreamsInTheStagedRoot() async throws {
        let (projectStore, store, piece) = try await openCollection(text: "As @tbl:w1 shows.\n")

        var t2 = FigureTable(rows: 2, columns: 2)
        let (a1, b2) = (CellKey(row: t2.rows[0], column: t2.columns[0]), CellKey(row: t2.rows[1], column: t2.columns[1]))
        t2.setCell(Cell(content: .value(.number(21))), at: a1)
        t2.setCell(Cell(content: .value(.number(0.5)), format: CellFormat(number: .percent(decimals: 0))), at: b2)
        t2.headerRows = 1
        t2.columnWidths[t2.columns[1]] = 90
        let w2 = try await projectStore.createFigureStream(
            kind: .table, table: t2, name: "w2", piece: nil, source: nil, site: "test")

        var t1 = FigureTable(rows: 1, columns: 1)
        let formula = Formula(.binary(.add,
            .binary(.multiply, .ref(FormulaRef(target: .figure(id: w2.id), anchor: .id(row: a1.row, column: a1.column))),
                    .number(2)),
            .ref(FormulaRef(target: .research(id: "res-left0000"), anchor: .position(row: 0, column: 0)))))
        let w1Cell = CellKey(row: t1.rows[0], column: t1.columns[0])
        t1.setCell(Cell(content: .formula(formula)), at: w1Cell)
        let w1 = try await projectStore.createFigureStream(
            kind: .table, table: t1, name: "w1", piece: nil, source: nil, site: "test")

        // The piece's own table, with a deleted row: its tombstone is re-created.
        var t3 = FigureTable(rows: 3, columns: 1)
        t3.setCell(Cell(content: .value(.text("kept"))), at: CellKey(row: t3.rows[2], column: t3.columns[0]))
        t3.deleteRow(t3.rows[1])
        let own = try await projectStore.createFigureStream(
            kind: .table, table: t3, name: "own", piece: piece.id, source: nil, site: "test")
        let map = try await projectStore.createImageFigure(fromURL: try png("map.png"), piece: piece.id)
        let parked = try await projectStore.createFigure(kind: .table, name: "parked", piece: piece.id)
        let copy = try await projectStore.sendToResearch(figureId: parked.id, scope: .document(piece.id))
        let other = try await projectStore.createFigure(kind: .table, name: "other", piece: nil)

        let sources = try await [w2, w1, own, map, parked].asyncMap { try await state($0.id, in: projectStore.url) }
        XCTAssertNotNil(sources[4].parked, "precondition: parked")
        let collectionOps = try [w2, w1, own, map, parked, other].map { try stream($0.id, in: projectStore.url).ops }

        // Which figures, and what stays behind.
        let plan = try await projectStore.figureCarryPlan(forPiece: piece.id, carriedResearch: [copy.id])
        XCTAssertEqual(plan.moved.map(\.id), [own.id, map.id, parked.id])
        XCTAssertEqual(plan.copied.map(\.id), [w2.id, w1.id], "w2 only through w1's formula; `other` stays")
        XCTAssertEqual(plan.problems, [
            FigureCarryProblem(figureId: w1.id, cell: w1Cell, source: "res-left0000", read: .formula),
        ])
        XCTAssertNil(plan.states[other.id])

        // The streams, re-created in a staged root.
        let staging = root.appendingPathComponent(".maugham-staging-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let newPiece = "doc-promoted"
        let records = plan.moved.map { var r = $0; r.piece = newPiece; return r } + plan.copied
        try await projectStore.writeCarriedFigureStreams(
            records, states: plan.states, parks: plan.parks, into: staging)
        let manifest = ProjectManifest(
            type: .shortStory, title: "Story A", author: "A", created: Date(), modified: Date(),
            structure: [], research: [], figures: records)
        try ProjectManifest.encodeForDisk(manifest).write(to: staging.appendingPathComponent(ProjectManifest.fileName))

        let author = Document.loadIdentities[.author].deviceId
        for (record, source) in zip([w2, w1, own, map, parked], sources) {
            let (ops, sealed) = try stream(record.id, in: staging)
            XCTAssertFalse(ops.isEmpty, record.name)
            XCTAssertEqual(Set(ops.map(\.device)), [author], "\(record.name): this Mac's author wrote it")
            XCTAssertEqual(Set(ops.map(\.docId)), [record.id], "\(record.name): its id is kept")
            XCTAssertEqual(sealed, [true], "\(record.name): one file, sealed")
            let made = try await state(record.id, in: staging)
            XCTAssertEqual(made.diagnostics, [], record.name)
            XCTAssertEqual(made.kind, source.kind, record.name)
            XCTAssertEqual(made.table, source.table, "\(record.name): the same table, ids and tombstones")
            XCTAssertEqual(made.image, source.image, record.name)
            XCTAssertEqual(made.pins, source.pins, record.name)
            XCTAssertEqual(made.parked?.path, source.parked?.path, record.name)
            XCTAssertEqual(made.parked?.itemId, source.parked?.itemId, record.name)
            XCTAssertEqual(made.parked?.hash, source.parked?.hash, record.name)
        }
        let parkOp = try XCTUnwrap(try stream(parked.id, in: staging).ops.last)
        XCTAssertEqual(parkOp.kind, .figureParked, "parked again, last")
        XCTAssertEqual(parkOp.figure?.parkedItemId, copy.id, "naming its carried working copy")
        let beforePark = try stream(parked.id, in: staging).ops.dropLast().last?.opId
        XCTAssertEqual(parkOp.figure?.parkedFrontier, [author: try XCTUnwrap(beforePark)])

        // The picture, copied under its own name.
        let picture = try XCTUnwrap(sources[3].image)
        let staged = staging.appendingPathComponent("figures/\(picture.filename)")
        XCTAssertEqual(try ContentHash.ofFile(staged), picture.contentHash)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: staging.appendingPathComponent(".maugham/ops/\(other.id).jsonl").path))
        XCTAssertTrue(try OpLogStore.opLogFileURLs(forDocId: other.id, in: staging).isEmpty, "`other` was not written")

        // The Collection is unchanged.
        XCTAssertEqual(projectStore.manifest.figures?.map(\.id), [w2.id, w1.id, own.id, map.id, parked.id, other.id])
        XCTAssertEqual(try [w2, w1, own, map, parked, other].map { try stream($0.id, in: projectStore.url).ops },
                       collectionOps)
        XCTAssertTrue(FileManager.default.fileExists(atPath: projectStore.url.appendingPathComponent(map.path).path))
        _ = store
    }

    /// The piece's text is read from its op log, never its `.md`: a label
    /// written into the file behind the op log's back names nothing.
    func test_theTextIsReadFromTheOpLog() async throws {
        let (projectStore, _, piece) = try await openCollection(text: "Nothing cited.\n")
        let cited = try await projectStore.createFigure(kind: .table, name: "cited", piece: nil)
        let file = projectStore.url.appendingPathComponent(try XCTUnwrap(piece.path))
        try "See @tbl:cited.\n".write(to: file, atomically: true, encoding: .utf8)

        let plan = try await projectStore.figureCarryPlan(forPiece: piece.id, carriedResearch: [])
        XCTAssertEqual(plan.copied.map(\.id), [], "the .md's label is not the text: \(cited.id) stays")
    }
}

private extension Array {
    func asyncMap<T>(_ transform: (Element) async throws -> T) async rethrows -> [T] {
        var out: [T] = []
        for each in self { out.append(try await transform(each)) }
        return out
    }
}
