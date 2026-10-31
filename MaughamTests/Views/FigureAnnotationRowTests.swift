import XCTest
@testable import Maugham
@testable import MaughamCore

/// **A queue row for a note on a table figure tells the truth** (report plan
/// 9c-1 Task 7, `FigureRowGate`): where it points ("C3 · Table: cash", or
/// "cells deleted"), what a suggestion proposes, a suggestion's Accept
/// disabled with "Accept it in the table", the verbs with no figure-stream
/// write taken away; the inspector's note line leads with the address; and
/// the queue's answers reach the figure's own host — lent for the act, ⌘Z
/// registered only where the window holds the figure open.
@MainActor
final class FigureAnnotationRowTests: XCTestCase {

    private let figureId = "fig-k3m9q2zt"
    private let title = "Table: cash"
    private let anchor = FigureCellAnchor(row: RowID("r1aaaaaa"), column: ColumnID("c1bbbbbb"))
    private let cells = SuggestionDisplay.FigureCells(before: "11.5", after: "12")

    private func note(
        _ kind: AnnotationKind, anchor: FigureCellAnchor?, address: String? = nil,
        orphaned: Bool = false, status: AnnotationStatus = .open
    ) -> Annotation {
        Annotation(
            id: "n1", kind: kind, paragraphId: nil, body: "Look",
            suggestedText: nil, priorText: nil, createdAt: Date(timeIntervalSince1970: 0),
            createdBySession: nil, status: status, userResponse: nil, resolvedAt: nil,
            isStale: orphaned, figureAnchor: anchor,
            suggestedCell: kind == .suggestedChange ? Cell(content: .value(.number(12))) : nil,
            figureAddress: address, figureOrphaned: orphaned)
    }

    // MARK: - The gate

    /// A suggestion: its address and figure, its cells, and Accept / Revert
    /// disabled with where to do it instead.
    func test_aSuggestionShowsItsCellAndIsAcceptedInTheTable() {
        let gate = FigureRowGate(
            annotation: note(.suggestedChange, anchor: anchor, address: "C3"),
            figureId: figureId, figureTitle: title, cells: cells)
        XCTAssertEqual(gate.anchorLine, "C3 \u{00B7} Table: cash")
        XCTAssertEqual(gate.cells, cells)
        XCTAssertEqual(gate.acceptDisabledReason, "Accept it in the table")
        XCTAssertEqual(gate.revertDisabledReason, FigureRowGate.revertInTheTable)
    }

    /// An orphaned anchor says so in place of its address; still the table's.
    func test_anOrphanedSuggestionSaysCellsDeleted() {
        let gate = FigureRowGate(
            annotation: note(.suggestedChange, anchor: anchor, orphaned: true),
            figureId: figureId, figureTitle: title, cells: .init(before: nil, after: "12"))
        XCTAssertEqual(gate.anchorLine, "cells deleted \u{00B7} Table: cash")
        XCTAssertEqual(gate.acceptDisabledReason, "Accept it in the table")
        XCTAssertNil(gate.cells?.before)
    }

    /// A comment, a query and a craft note write no cell: their Accept /
    /// *Got it* / Reply work from the queue, and they carry no cells. A
    /// whole-figure note's line is the figure's title alone.
    func test_notesThatWriteNoCellAreActableFromTheQueue() {
        for kind in [AnnotationKind.comment, .query, .craftNote] {
            let gate = FigureRowGate(
                annotation: note(kind, anchor: kind == .craftNote ? nil : anchor,
                                 address: kind == .craftNote ? nil : "B2"),
                figureId: figureId, figureTitle: title, cells: cells)
            XCTAssertNil(gate.acceptDisabledReason, "\(kind)")
            XCTAssertNil(gate.revertDisabledReason, "\(kind)")
            XCTAssertNil(gate.cells, "\(kind): only a suggestion carries cells")
            XCTAssertEqual(gate.anchorLine,
                           kind == .craftNote ? "Table: cash" : "B2 \u{00B7} Table: cash", "\(kind)")
        }
    }

    /// The posture still decides Accept/Reject and the dispositions; the
    /// verbs with no figure-stream write are taken away whatever it says.
    func test_theVerbsNarrowToWhatAFigureStreamCanWrite() {
        for isOwn in [false, true] {
            XCTAssertEqual(
                FigureRowGate.verbs(.unrestricted(isOwn: isOwn)),
                AnnotationRowVerbs(acceptOrReject: true, dispose: true, answerAsRuling: false,
                                   makeChoice: false, keepAsLesson: false, ownNote: false))
        }
        let reviewer = AnnotationRowVerbs(
            acceptOrReject: false, dispose: false, answerAsRuling: false,
            makeChoice: false, keepAsLesson: true, ownNote: true)
        XCTAssertEqual(
            FigureRowGate.verbs(reviewer),
            AnnotationRowVerbs(acceptOrReject: false, dispose: false, answerAsRuling: false,
                               makeChoice: false, keepAsLesson: false, ownNote: false),
            "a reviewer's posture offers no answer on a figure either")
        XCTAssertFalse(FigureRowGate.drawsTriage, "no figure-stream verb writes a triage mark")
    }

    /// A read-only host's figure verbs are inert.
    func test_theReadOnlyWiringsFigureVerbsAreInert() {
        let wiring = AnnotationRowWiring.readOnly(manifest: nil)
        let n = note(.comment, anchor: anchor)
        wiring.figure.onAccept(figureId, n)
        wiring.figure.onReject(figureId, n)
        wiring.figure.onStet(figureId, n)
        wiring.figure.onArchive(figureId, n)
        wiring.figure.onReply(figureId, n)
        wiring.figure.onReopen(figureId, n)
    }

    // MARK: - The inspector

    /// The inspector's note line leads with the address, "cells deleted",
    /// or nothing for the whole figure.
    func test_theInspectorsNoteLineLeadsWithTheAddress() {
        XCTAssertEqual(FigureInspector.noteHeading(note(.comment, anchor: anchor, address: "C3")),
                       "C3 \u{00B7} Comment \u{00B7} open")
        XCTAssertEqual(FigureInspector.noteHeading(note(.suggestedChange, anchor: anchor, orphaned: true)),
                       "cells deleted \u{00B7} Suggestion \u{00B7} open")
        XCTAssertEqual(FigureInspector.noteHeading(note(.craftNote, anchor: nil, status: .stetted)),
                       "Craft note \u{00B7} stetted")
    }
}

/// **The queue's answers reach the figure's own host** (report plan 9c-1
/// Task 7): a figure no window holds is lent for the act and closed after it
/// (`withFigureHost`), and only a figure the window holds open registers the
/// act's ⌘Z (`holdsFigureOpen`).
@MainActor
final class FigureAnnotationQueueHostTests: XCTestCase {

    private var projectURL: URL!

    override func setUp() async throws {
        projectURL = TestTemp.root.appendingPathComponent("fignote-queue-\(UUID().uuidString)")
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
        let figure = try await projectStore.createFigure(kind: .table, name: "cash", piece: "doc-a")
        return (store, projectStore, figure)
    }

    private func query(on figure: FigureRecord, store: DocumentStore) async throws -> Op {
        let table = try await store.withFigureHost(figure.id) { $0.state.table }
        let op = try FigureAnnotationOps.creation(
            kind: .query, anchor: FigureCellAnchor(row: table.rows[0], column: table.columns[0]),
            body: "Source?", author: AnnotationAuthor(sourceKind: .claude, displayName: "Claude"),
            stamp: .init(figureId: figure.id, device: Document.loadIdentities[.assistant].deviceId))
        try await store.addFigureAnnotation(op)
        return op
    }

    /// A reply from the queue on a figure no window holds: the host is lent,
    /// the reply lands, and the host is closed after; the figure is not held,
    /// so no ⌘Z would be registered. Once a grid holds it open, it is.
    func test_aReplyFromTheQueueLandsThroughALentHost_andOnlyAHeldFigureTakesUndo() async throws {
        let (store, projectStore, figure) = try await openBook()
        let q = try await query(on: figure, store: store)
        XCTAssertFalse(store.holdsFigureOpen(figure.id), "premise: no window holds it")

        try await store.withFigureHost(figure.id) { host in
            try await host.acceptNote(id: q.opId, userResponse: "The census")
        }

        XCTAssertNil(store.openFigure(forId: figure.id), "the lent host was closed after the act")
        XCTAssertFalse(store.holdsFigureOpen(figure.id))
        let notes = await projectStore.figureNotes(figure.id)
        XCTAssertEqual(notes.first?.status, .accepted)
        XCTAssertEqual(notes.first?.userResponse, "The census")

        _ = try await store.openFigure(figureId: figure.id)
        XCTAssertTrue(store.holdsFigureOpen(figure.id), "a grid's open figure takes the act's ⌘Z")
        await store.closeFigure(figureId: figure.id)
        XCTAssertFalse(store.holdsFigureOpen(figure.id))
    }

    /// A refused answer is a sentence the writer is told (a deleted note's
    /// typed refusal), never swallowed.
    func test_aRefusedAnswerIsSaid() async throws {
        let (store, _, _) = try await openBook()
        let sentence = AnnotationsPane.sayRefused(FigureNoteError.withdrawn, projectURL: store.projectURL)
        XCTAssertEqual(sentence, "That note was deleted.")
    }
}
