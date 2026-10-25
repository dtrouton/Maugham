import XCTest
import AppKit
@testable import Maugham
@testable import MaughamCore

/// **A figure wound back to a checkpoint on the Mac** (report plan 6c Task 2,
/// rulings Q-1, Q-2): `FigureDocument.restoreToCheckpoint` appends
/// `FigureRestoreDiff`'s changes as ordinary figure ops, each carrying the
/// checkpoint's id, behind the figure's own door; a parked figure is
/// skipped; a picture comes back only when its bytes are still on disk.
@MainActor
final class FigureRestoreTests: XCTestCase {

    private var projectURL: URL!
    private static let pieceB = "doc-b"
    private static let checkpoint = "ckpt-restore"

    override func setUp() async throws {
        projectURL = TestTemp.root.appendingPathComponent("figrestore-\(UUID().uuidString)")
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
        FigureDocument.beforeCommitAppendForTesting = nil
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

    /// Every op in every file of the figure's stream, seals excluded, by id.
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

    private func streamBytes(of figureId: String) throws -> [String: Data] {
        var out: [String: Data] = [:]
        for url in OpLogStore.opLogFileURLs(forDocId: figureId, in: projectURL) {
            out[url.lastPathComponent] = try Data(contentsOf: url)
        }
        return out
    }

    private func text(_ s: String) -> Cell { Cell(content: .value(.text(s))) }

    /// Another Mac, admitted as a whole-book author so its lines are read.
    private func admitAnotherMac(_ store: DocumentStore) async throws -> LocalIdentities {
        let other = LocalIdentities.softwareForTesting()
        _ = try await store.admit(
            device: other.author.fingerprint, label: "Ada", ownName: "Ada’s Mac",
            permit: .author(.book))
        await store.postureSettled()
        return other
    }

    /// `other`'s op on figure `id`, appended and sealed under its own identity.
    private func theirOp(
        _ other: LocalIdentities, _ id: String, _ kind: OpKind, _ payload: FigureOpPayload
    ) async throws {
        let theirs = OpLogStore(
            projectURL: projectURL, identities: other,
            state: OpLogDeviceState(fileURL: projectURL.appendingPathComponent("other-\(UUID().uuidString).json")))
        try await theirs.append(Op(
            opId: ULID.generate(), docId: id, at: Date(), device: other.author.deviceId,
            session: "x", kind: kind, changes: [], figure: payload))
        _ = try await theirs.sealChain(docId: id)
    }

    /// The figure at `pointer`, as the restore's caller derives it.
    private func target(_ host: FigureDocument, through pointer: String) -> FigureState {
        FigureRestoreDiff.target(of: host._ops, through: pointer)
    }

    /// The newest op in the stream: what the restore appends sorts after it.
    private func mark(_ id: String) throws -> String {
        try XCTUnwrap(try ops(of: id).map(\.opId).max())
    }

    /// Exactly `count` ops follow `mark`, each this host's own and each
    /// carrying the checkpoint.
    private func assertStamped(
        after mark: String, _ id: String, _ host: FigureDocument, count: Int,
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let since = try ops(of: id).filter { $0.opId > mark }
        XCTAssertEqual(since.count, count, "the restore's ops", file: file, line: line)
        for op in since {
            XCTAssertEqual(op.device, host.device, "\(op.kind)", file: file, line: line)
            XCTAssertEqual(op.provenance?.sourceCheckpoint, Self.checkpoint, "\(op.kind)", file: file, line: line)
        }
    }

    /// A real PNG outside the project, of one colour, so two colours hash apart.
    private func png(_ name: String, _ color: NSColor) throws -> URL {
        let dir = TestTemp.root.appendingPathComponent("figrestore-png-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let image = NSImage(size: NSSize(width: 4, height: 4))
        image.lockFocus()
        color.setFill()
        NSRect(x: 0, y: 0, width: 4, height: 4).fill()
        image.unlockFocus()
        let url = dir.appendingPathComponent(name)
        try ImagePasteHandler.encodePNG(image).write(to: url)
        return url
    }

    // MARK: - Review Focus 1

    /// **A checkpoint taken before a row was deleted and a column added,
    /// after another device edited a cell in the added column**: the row
    /// returns in its slot with its cell, the column goes, the figure equals
    /// the checkpoint cell for cell, and every op the restore appended
    /// carries the checkpoint and is this host's — read back from the stream.
    func test_reviewFocus1_aHostRestoresTheCheckpointAndEveryOpCarriesIt() async throws {
        let (store, projectStore) = try await openBook()
        let record = try await projectStore.createFigure(kind: .table, name: "budget", piece: nil)
        let host = try await store.openFigure(figureId: record.id)
        let rows = host.state.table.rows, columns = host.state.table.columns
        try await host.setCell(text("Lodging"), at: CellKey(row: rows[1], column: columns[0]))
        try await host.setCell(text("Food"), at: CellKey(row: rows[2], column: columns[0]))
        let pointer = try XCTUnwrap(host._ops.map(\.opId).max())
        let then = target(host, through: pointer)

        try await host.deleteRow(rows[1])
        let added = try await host.insertColumn(after: columns[2])
        let other = try await admitAnotherMac(store)
        try await theirOp(other, record.id, .figureCellSet, FigureOpPayload(
            cell: CellKey(row: rows[2], column: added), next: text("theirs"), prior: nil))
        try await host.reload()
        XCTAssertEqual(host.state.table[CellKey(row: rows[2], column: added)], text("theirs"),
                       "precondition: the other device's edit is read")

        let before = try mark(record.id)
        let outcome = try await host.restoreToCheckpoint(Self.checkpoint, target: then)

        XCTAssertEqual(outcome, .restored(opCount: 2), "the column deleted, the row revived")
        XCTAssertEqual(host.state.table.rows, rows, "the row is back in its own slot")
        XCTAssertEqual(host.state.table.columns, columns, "the added column is gone")
        XCTAssertEqual(host.state.table.cells, then.table.cells, "cell for cell")
        try assertStamped(after: before, record.id, host, count: 2)
        let delete = try XCTUnwrap(try ops(of: record.id).first {
            $0.figure?.structure == .deleteColumn(added) })
        XCTAssertEqual(delete.figure?.removed?.cells, [.init(at: rows[2].raw, cell: text("theirs"))],
                       "the delete keeps what it took, the other device's edit included")

        try await host.reload()
        XCTAssertEqual(host.state.table.rows, rows, "the stream says so too")
        XCTAssertEqual(host.state.table.cells, then.table.cells)
        let again = try await host.restoreToCheckpoint(Self.checkpoint, target: then)
        XCTAssertEqual(again, .unchanged, "a restored figure needs no second restore")
        await store.closeFigure(figureId: record.id)
    }

    // MARK: - Skipped and refused

    /// **A parked figure is skipped** (ruling Q-1): nothing is appended.
    func test_aParkedFigureIsSkipped() async throws {
        let (store, projectStore) = try await openBook()
        let record = try await projectStore.createFigure(kind: .table, name: "budget", piece: nil)
        let host = try await store.openFigure(figureId: record.id)
        let key = CellKey(row: host.state.table.rows[0], column: host.state.table.columns[0])
        let pointer = try XCTUnwrap(host._ops.map(\.opId).max())
        let then = target(host, through: pointer)
        try await host.setCell(text("since"), at: key)
        try await host.parkInResearch(
            path: "research/budget.csv", hash: "h", itemId: "item-1", expecting: host.state, alongside: {})
        let before = try streamBytes(of: record.id)

        let outcome = try await host.restoreToCheckpoint(Self.checkpoint, target: then)

        XCTAssertEqual(outcome, .skippedParked)
        XCTAssertEqual(try streamBytes(of: record.id), before, "nothing was appended")
        await store.closeFigure(figureId: record.id)
    }

    /// **A figure this Mac may not change refuses before any op** (ruling
    /// Q-2): its piece is yielded to Sam.
    func test_aRefusedPostureThrowsBeforeAnyOp() async throws {
        let (store, projectStore) = try await openBook()
        let record = try await projectStore.createFigure(kind: .table, name: "b_table", piece: Self.pieceB)
        let host = try await store.openFigure(figureId: record.id)
        let pointer = try XCTUnwrap(host._ops.map(\.opId).max())
        let then = target(host, through: pointer)
        try await host.setCell(text("since"), at: CellKey(
            row: host.state.table.rows[0], column: host.state.table.columns[0]))
        let sam = LocalIdentities.softwareForTesting()
        _ = try await store.admit(
            device: sam.author.fingerprint, label: "Sam", ownName: "Sam’s Mac",
            permit: .author(.pieces([Self.pieceB])))
        await store.postureSettled()
        let before = try streamBytes(of: record.id)

        do {
            _ = try await host.restoreToCheckpoint(Self.checkpoint, target: then)
            XCTFail("a restore of a yielded piece's figure was not refused")
        } catch let refused as FigureEditRefused {
            XCTAssertEqual(refused.site, "restoreToCheckpoint")
        }
        XCTAssertEqual(try streamBytes(of: record.id), before, "nothing was appended")
        await store.closeFigure(figureId: record.id)
    }

    // MARK: - Pictures

    /// **A picture whose bytes this host still keeps comes back**: replaced
    /// since the checkpoint, the old picture is in the host's undo folder, so
    /// the file takes its bytes again under its own name, with one op.
    func test_aPictureKeptInTheUndoFolderComesBack() async throws {
        let (store, projectStore) = try await openBook()
        let red = try png("chart.png", .red)
        let record = try await projectStore.createImageFigure(fromURL: red, piece: nil)
        let host = try await store.openFigure(figureId: record.id)
        let pointer = try XCTUnwrap(host._ops.map(\.opId).max())
        let then = target(host, through: pointer)
        try await host.setImage(fromURL: try png("blue.png", .blue))

        let before = try mark(record.id)
        let outcome = try await host.restoreToCheckpoint(Self.checkpoint, target: then)

        XCTAssertEqual(outcome, .restored(opCount: 1))
        XCTAssertEqual(try Data(contentsOf: file("figures/chart.png")), try Data(contentsOf: red))
        XCTAssertEqual(host.state.image, then.image)
        try assertStamped(after: before, record.id, host, count: 1)
        await store.closeFigure(figureId: record.id)
    }

    /// **A picture whose bytes are in `figures/` under another name comes
    /// back** — after the host that kept it closed — written over the
    /// figure's own file.
    func test_aPictureWhoseBytesAreInFiguresComesBack() async throws {
        let (store, projectStore) = try await openBook()
        let red = try png("chart.png", .red)
        let record = try await projectStore.createImageFigure(fromURL: red, piece: nil)
        var host = try await store.openFigure(figureId: record.id)
        let pointer = try XCTUnwrap(host._ops.map(\.opId).max())
        try await host.setImage(fromURL: try png("blue.png", .blue))
        await store.closeFigure(figureId: record.id)
        try FileManager.default.copyItem(at: red, to: file("figures/kept-elsewhere.png"))
        host = try await store.openFigure(figureId: record.id)
        let then = target(host, through: pointer)

        let before = try mark(record.id)
        let outcome = try await host.restoreToCheckpoint(Self.checkpoint, target: then)

        XCTAssertEqual(outcome, .restored(opCount: 1))
        XCTAssertEqual(try Data(contentsOf: file("figures/chart.png")), try Data(contentsOf: red))
        XCTAssertEqual(host.state.image, then.image, "the file keeps its name")
        await store.closeFigure(figureId: record.id)
    }

    /// **A picture whose bytes are gone is skipped and named; the rest is
    /// restored**: here the rest is a row another device added to the
    /// figure's table since, which the restore deletes; the file is untouched.
    func test_aPictureWithMissingBytesRestoresTheRestAndReportsThePicture() async throws {
        let (store, projectStore) = try await openBook()
        let red = try png("chart.png", .red)
        let record = try await projectStore.createImageFigure(fromURL: red, piece: nil)
        var host = try await store.openFigure(figureId: record.id)
        let pointer = try XCTUnwrap(host._ops.map(\.opId).max())
        let redHash = try XCTUnwrap(host.state.image?.contentHash)
        try await host.setImage(fromURL: try png("blue.png", .blue))
        await store.closeFigure(figureId: record.id)  // its undo folder goes with it
        let blueBytes = try Data(contentsOf: file("figures/chart.png"))
        let other = try await admitAnotherMac(store)
        try await theirOp(other, record.id, .figureStructure, FigureOpPayload(
            structure: .insertRow(RowID("r-since"), after: nil)))
        host = try await store.openFigure(figureId: record.id)
        XCTAssertEqual(host.state.table.rows, [RowID("r-since")], "precondition: their row is read")
        let then = target(host, through: pointer)

        let before = try mark(record.id)
        let outcome = try await host.restoreToCheckpoint(Self.checkpoint, target: then)

        XCTAssertEqual(outcome, .skippedPicture(hash: redHash))
        XCTAssertEqual(host.state.table.rows, [], "the rest was restored")
        XCTAssertEqual(try Data(contentsOf: file("figures/chart.png")), blueBytes, "the file is untouched")
        XCTAssertNotEqual(host.state.image?.contentHash, redHash)
        try assertStamped(after: before, record.id, host, count: 1)
        await store.closeFigure(figureId: record.id)
    }

    // MARK: - The park ruling (plan 6c Task 1 review)

    /// **A pin live now is never replaced by one inert now**: `total` reads
    /// `cash`, which was parked, brought back and parked again since the
    /// checkpoint. The checkpoint's pin is from the first park, inert under
    /// the second; the pin from the second counts, so it stays — the host
    /// passes the book's current park cycles to the diff.
    func test_aPinFromTheCurrentParkStaysOverTheCheckpointsPinFromAnEarlierOne() async throws {
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

        let first = try await projectStore.sendToResearch(figureId: cash.id, scope: .shared)
        try Data(",,\n7,,\n,,\n".utf8).write(to: file(try XCTUnwrap(first.path)))
        try await totalDoc.refreshPins()
        XCTAssertEqual(totalDoc.state.pins[t1]?.map(\.park), [first.id], "precondition: the first park's pin")
        let pointer = try XCTUnwrap(totalDoc._ops.map(\.opId).max())
        let then = target(totalDoc, through: pointer)

        // The copy put back as it was parked, so the figure comes back unchanged.
        try Data(",,\n5,,\n,,\n".utf8).write(to: file(try XCTUnwrap(first.path)))
        _ = try await projectStore.bringBack(researchItemId: first.id, piece: nil)
        let second = try await projectStore.sendToResearch(figureId: cash.id, scope: .shared)
        try Data(",,\n9,,\n,,\n".utf8).write(to: file(try XCTUnwrap(second.path)))
        try await totalDoc.refreshPins()
        let live = try XCTUnwrap(totalDoc.state.pins[t1])
        XCTAssertEqual(live.map(\.park), [second.id], "precondition: the second park's pin")
        XCTAssertFalse(FigureRestoreDiff.changes(from: totalDoc.state, to: then, parks: [:]).isEmpty,
                       "precondition: without the book's parks the checkpoint's pin would come back")

        let outcome = try await totalDoc.restoreToCheckpoint(Self.checkpoint, target: then)

        XCTAssertEqual(outcome, .unchanged)
        XCTAssertEqual(totalDoc.state.pins[t1], live, "the pin that counts stays")
        await store.closeFigure(figureId: total.id)
    }
}
