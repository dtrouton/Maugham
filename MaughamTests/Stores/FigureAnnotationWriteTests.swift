import XCTest
@testable import Maugham
@testable import MaughamCore

/// **The store writes a figure note** (report plan 9c-1 Task 3,
/// `DocumentStore.addFigureAnnotation`): the creation lands on the figure's
/// own stream under the device it names — the assistant's for an MCP note —
/// windowless, or through the open host so its fold and its next edit see it;
/// the figure's notes reader finds it; the change is announced once; a parked
/// figure refuses before anything is written.
@MainActor
final class FigureAnnotationWriteTests: XCTestCase {

    private var projectURL: URL!

    override func setUp() async throws {
        projectURL = TestTemp.root.appendingPathComponent("fignote-\(UUID().uuidString)")
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

    /// A book with one chapter and a window over it, plus one 3×3 table figure.
    private func openBook() async throws -> (DocumentStore, ProjectStore, FigureRecord) {
        try "Words.\n".write(to: projectURL.appendingPathComponent("manuscript/a.md"),
                             atomically: true, encoding: .utf8)
        let manifest = ProjectManifest(
            type: .novel, title: "T", author: "A", created: Date(), modified: Date(),
            structure: [StructureItem(id: "doc-a", title: "A", type: .document, path: "manuscript/a.md")],
            research: [])
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        try enc.encode(manifest).write(to: projectURL.appendingPathComponent(ProjectManifest.fileName))
        let store = try await DocumentStore.open(url: projectURL)
        let doc = try await Document.load(
            url: projectURL.appendingPathComponent("manuscript/a.md"),
            actor: .author, session: "boot", presenter: nil)
        await doc.close()
        let projectStore = try await ProjectStore.load(from: projectURL)
        projectStore.documentStore = store
        store.projectStore = projectStore
        let figure = try await projectStore.createFigure(kind: .table, name: "cash", piece: nil)
        return (store, projectStore, figure)
    }

    private var assistantDevice: String { Document.loadIdentities[.assistant].deviceId }

    /// A comment on the figure's first cell, stamped as the assistant's.
    private func assistantComment(
        on figure: FigureRecord, table: FigureTable, body: String
    ) throws -> Op {
        try FigureAnnotationOps.creation(
            kind: .comment,
            anchor: FigureCellAnchor(row: table.rows[0], column: table.columns[0]),
            body: body, author: AnnotationAuthor(sourceKind: .claude, displayName: "Claude"),
            stamp: .init(figureId: figure.id, device: assistantDevice))
    }

    /// The figure's table as its stream says, read through a transient host.
    private func table(_ figure: FigureRecord, _ store: DocumentStore) async throws -> FigureTable {
        try await store.withFigureHost(figure.id) { $0.state.table }
    }

    /// The figure's stream file for the assistant's device.
    private func assistantStream(_ figure: FigureRecord) throws -> URL {
        try OpLogStore.opLogFileURL(
            forDocId: figure.id, deviceSlug: DeviceSlug.make(from: assistantDevice), in: projectURL)
    }

    // MARK: - Tests

    /// **Windowless**: the note lands in the figure's `.assistant-` stream —
    /// the assistant's own file, chained under its key — and the figure's
    /// notes reader finds it on its cell.
    func test_aWindowlessNoteLandsInTheAssistantsStreamAndIsRead() async throws {
        let (store, projectStore, figure) = try await openBook()
        let table = try await table(figure, store)
        XCTAssertNil(store.openFigure(forId: figure.id), "premise: no host is held")
        let op = try assistantComment(on: figure, table: table, body: "Is this right?")

        try await store.addFigureAnnotation(op)

        let file = try assistantStream(figure)
        XCTAssertTrue(file.lastPathComponent.contains(".assistant-"), file.lastPathComponent)
        let lines = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(lines.contains(op.opId), "the note is in the assistant's own stream")
        XCTAssertEqual(Document.loadIdentities.identity(forDeviceId: op.device)?.actor, .assistant,
                       "the device that signs it is the assistant's")
        let notes = await projectStore.figureNotes(figure.id)
        XCTAssertEqual(notes.map(\.body), ["Is this right?"])
        XCTAssertEqual(notes.first?.figureAnchor?.row, table.rows[0])
    }

    /// **A windowless note is sealed**: the store it was appended with dies
    /// with the call, so the assistant's file must end on a seal line there
    /// and then — no cadence or close would ever sign it (final review M1).
    func test_aWindowlessNoteIsSealedInTheAssistantsFile() async throws {
        let (store, projectStore, figure) = try await openBook()
        let table = try await table(figure, store)
        try await store.addFigureAnnotation(try assistantComment(on: figure, table: table, body: "Sealed?"))
        withExtendedLifetime(projectStore) {}
        let lines = try Data(contentsOf: try assistantStream(figure))
            .split(separator: UInt8(0x0A), omittingEmptySubsequences: true)
        let last = try XCTUnwrap(lines.last)
        XCTAssertTrue(OpLogChain.isSealLine(Data(last)), "the assistant's file ends on a seal line")
    }

    /// **Through the open host**: the host's streams and fold carry the note,
    /// its next edit is minted after it (the frontier advanced, even past a
    /// note whose id sorts in the future), and that edit drops nothing.
    func test_anOpenHostSeesTheNoteAndItsNextWriteKeepsIt() async throws {
        let (store, projectStore, figure) = try await openBook()
        let host = try await store.openFigure(figureId: figure.id)
        let a1 = CellKey(row: host.state.table.rows[0], column: host.state.table.columns[0])
        let built = try assistantComment(on: figure, table: host.state.table, body: "Check the sum")
        // The note's id sorts a minute ahead of this Mac's clock.
        let future = ULID.generate(atMillis: UInt64(Date().timeIntervalSince1970 * 1000) + 60_000)
        let op = Op(opId: future, docId: built.docId, at: built.at, device: built.device,
                    session: built.session, kind: built.kind, changes: [],
                    provenance: built.provenance, figure: built.figure)

        try await store.addFigureAnnotation(op)

        XCTAssertTrue(host._ops.contains { $0.opId == op.opId }, "the host's fold read the note")
        XCTAssertEqual(host.streams[assistantDevice]?.last, op.opId, "the host's frontier holds it")

        try await host.setCell(Cell(content: .value(.number(7))), at: a1)
        let edit = try XCTUnwrap(host._ops.last)
        XCTAssertEqual(edit.kind, .figureCellSet)
        XCTAssertGreaterThan(edit.opId, op.opId, "the next edit is minted after the note")
        XCTAssertEqual(host.state.table.cells[a1]?.content, .value(.number(7)))
        XCTAssertTrue(host._ops.contains { $0.opId == op.opId }, "the edit dropped nothing")
        let notes = await projectStore.figureNotes(figure.id)
        XCTAssertEqual(notes.map(\.body), ["Check the sum"], "the note survives the host's write")
        await store.closeFigure(figureId: figure.id)
    }

    /// **The change is announced once, naming the figure** — windowless and
    /// through a host alike.
    func test_theChangeIsAnnouncedOnceWithTheFigureId() async throws {
        // The window's `projectStore` is weak: held here, as a session holds it.
        let (store, projectStore, figure) = try await openBook()
        defer { withExtendedLifetime(projectStore) {} }
        let table = try await table(figure, store)
        var heard: [String] = []
        let token = NotificationCenter.default.addObserver( // adr-0021-ok: a test observing the production post, not a production subscription
            forName: .maughamAnnotationsChanged, object: nil, queue: nil
        ) { note in
            guard let id = note.userInfo?[MaughamEvent.annotationDocIdKey] as? String,
                  id == figure.id else { return }
            heard.append(id)
        }
        defer { NotificationCenter.default.removeObserver(token) }

        try await store.addFigureAnnotation(try assistantComment(on: figure, table: table, body: "one"))
        XCTAssertEqual(heard, [figure.id], "windowless: once")

        _ = try await store.openFigure(figureId: figure.id)
        try await store.addFigureAnnotation(try assistantComment(on: figure, table: table, body: "two"))
        XCTAssertEqual(heard, [figure.id, figure.id], "through the host: once more")
        await store.closeFigure(figureId: figure.id)
    }

    /// **A parked figure refuses**, open or not, and nothing is written.
    func test_aParkedFigureRefusesAndNothingIsWritten() async throws {
        let (store, projectStore, figure) = try await openBook()
        let table = try await table(figure, store)
        _ = try await projectStore.sendToResearch(figureId: figure.id, scope: .shared)
        let op = try assistantComment(on: figure, table: table, body: "parked")

        do {
            try await store.addFigureAnnotation(op)
            XCTFail("a parked figure takes no note")
        } catch is FigureParkedRefused {}

        _ = try await store.openFigure(figureId: figure.id)
        do {
            try await store.addFigureAnnotation(op)
            XCTFail("a parked figure's open host takes no note either")
        } catch is FigureParkedRefused {}
        await store.closeFigure(figureId: figure.id)

        XCTAssertFalse(FileManager.default.fileExists(atPath: try assistantStream(figure).path),
                       "nothing was appended")
        let notes = await projectStore.figureNotes(figure.id)
        XCTAssertEqual(notes, [])
    }

    /// **Only a note's creation, only on a listed figure**: a disposition and
    /// an unknown figure are refused before anything is written.
    func test_aDispositionOrAnUnknownFigureIsRefused() async throws {
        let (store, projectStore, figure) = try await openBook()
        defer { withExtendedLifetime(projectStore) {} }
        let stet = FigureAnnotationOps.stet(
            annotationId: "n1", stamp: .init(figureId: figure.id, device: assistantDevice))
        do {
            try await store.addFigureAnnotation(stet)
            XCTFail("a disposition is the author's, not this door's")
        } catch let error as FigureAnnotationWriteError {
            XCTAssertEqual(error, .notANoteCreation(.annotationStet))
        }

        let stranger = try FigureAnnotationOps.creation(
            kind: .craftNote, anchor: nil, body: "x", author: nil,
            stamp: .init(figureId: "fig-nope", device: assistantDevice))
        do {
            try await store.addFigureAnnotation(stranger)
            XCTFail("an unlisted figure takes no note")
        } catch let error as FigureAnnotationWriteError {
            XCTAssertEqual(error, .unknownFigure("fig-nope"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: try assistantStream(figure).path))
    }
}
