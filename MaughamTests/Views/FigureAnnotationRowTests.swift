import XCTest
@testable import Maugham
@testable import MaughamCore

/// **A queue row for a note on a table figure tells the truth** (report plan
/// 9c-1 Task 7, `FigureRowGate`): where it points ("C3 · Table: cash", or
/// "cells deleted"), what a suggestion proposes, a suggestion's Accept
/// opening the figure at its cell (9c-2 Task 7) or, its cell gone, disabled
/// with "Its cell has been deleted", the verbs with no figure-stream
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

    /// A suggestion: its address and figure, its cells; Accept opens the
    /// table at its cell (the strip there writes it), saying so; an
    /// accepted one's Revert is disabled with where to do it instead.
    func test_aSuggestionShowsItsCell_andItsAcceptOpensTheTableAtIt() {
        let gate = FigureRowGate(
            annotation: note(.suggestedChange, anchor: anchor, address: "C3"),
            figureId: figureId, figureTitle: title, cells: cells)
        XCTAssertEqual(gate.anchorLine, "C3 \u{00B7} Table: cash")
        XCTAssertEqual(gate.cells, cells)
        XCTAssertNil(gate.acceptDisabledReason, "Accept works: it travels")
        XCTAssertTrue(gate.acceptTravels)
        XCTAssertEqual(gate.acceptHelp, "Open the table at its cell to accept it there")
        XCTAssertEqual(gate.revertDisabledReason, FigureRowGate.revertInTheTable)
    }

    /// An orphaned anchor says so in place of its address; Accept has no
    /// cell to open, so it is disabled saying why.
    func test_anOrphanedSuggestionSaysCellsDeleted_andItsAcceptIsOff() {
        let gate = FigureRowGate(
            annotation: note(.suggestedChange, anchor: anchor, orphaned: true),
            figureId: figureId, figureTitle: title, cells: .init(before: nil, after: "12"))
        XCTAssertEqual(gate.anchorLine, "cells deleted \u{00B7} Table: cash")
        XCTAssertEqual(gate.acceptDisabledReason, "Its cell has been deleted")
        XCTAssertFalse(gate.acceptTravels)
        XCTAssertEqual(gate.acceptHelp, "Its cell has been deleted")
        XCTAssertNil(gate.cells?.before)
        let unanchored = FigureRowGate(
            annotation: note(.suggestedChange, anchor: nil),
            figureId: figureId, figureTitle: title, cells: nil)
        XCTAssertEqual(unanchored.acceptDisabledReason, FigureRowGate.acceptCellDeleted,
                       "a figure suggestion whose anchor will not decode opens nothing either")
        XCTAssertFalse(unanchored.acceptTravels)
    }

    /// **A parked figure's suggestion** (fix round 1, I1): the queue cannot
    /// travel to a figure the tree draws no row for, so Accept is off,
    /// saying where the figure is; its cell gone, the cell's reason wins.
    func test_aParkedFiguresSuggestionAcceptIsOff_sayingItIsInResearch() {
        let gate = FigureRowGate(
            annotation: note(.suggestedChange, anchor: anchor, address: "C3"),
            figureId: figureId, figureTitle: title, cells: cells, reachable: false)
        XCTAssertEqual(gate.acceptDisabledReason, "In Research \u{2014} bring it back to accept")
        XCTAssertFalse(gate.acceptTravels)
        XCTAssertEqual(gate.acceptHelp, FigureRowGate.acceptInResearch)
        let orphaned = FigureRowGate(
            annotation: note(.suggestedChange, anchor: anchor, orphaned: true),
            figureId: figureId, figureTitle: title, cells: nil, reachable: false)
        XCTAssertEqual(orphaned.acceptDisabledReason, FigureRowGate.acceptCellDeleted)
        let comment = FigureRowGate(
            annotation: note(.comment, anchor: anchor, address: "C3"),
            figureId: figureId, figureTitle: title, cells: nil, reachable: false)
        XCTAssertNil(comment.acceptDisabledReason, "Got it still answers from the queue")
    }

    /// **The cell a note's travel selects**: a live anchor's first corner
    /// (a range's too — the strip shows every note whose range contains
    /// the active cell); none for an orphaned or a whole-figure note.
    func test_theTravelCellIsTheLiveAnchorsFirstCorner() {
        XCTAssertEqual(FigureRowGate.cell(of: note(.comment, anchor: anchor, address: "C3")),
                       CellKey(row: anchor.row, column: anchor.column))
        let range = FigureCellAnchor(row: RowID("r1aaaaaa"), rowEnd: RowID("r2aaaaaa"),
                                     column: ColumnID("c1bbbbbb"), columnEnd: ColumnID("c2bbbbbb"))
        XCTAssertEqual(FigureRowGate.cell(of: note(.suggestedChange, anchor: range, address: "C3:D4")),
                       CellKey(row: RowID("r1aaaaaa"), column: ColumnID("c1bbbbbb")))
        XCTAssertNil(FigureRowGate.cell(of: note(.comment, anchor: anchor, orphaned: true)))
        XCTAssertNil(FigureRowGate.cell(of: note(.craftNote, anchor: nil)))
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
            XCTAssertFalse(gate.acceptTravels, "\(kind): its Accept answers from the queue")
            XCTAssertNil(gate.acceptHelp, "\(kind)")
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

    /// An accepted note that wrote no cell reopens from the row (fix round
    /// 1, I2); an accepted suggestion keeps its disabled Revert instead.
    func test_anAcceptedCelllessNoteReopensFromTheRow_aSuggestionDoesNot() {
        for kind in [AnnotationKind.comment, .query, .craftNote] {
            XCTAssertTrue(FigureRowGate(
                annotation: note(kind, anchor: nil, status: .accepted),
                figureId: figureId, figureTitle: title, cells: nil).reopensAnAccept, "\(kind)")
        }
        let suggestion = FigureRowGate(
            annotation: note(.suggestedChange, anchor: anchor, address: "C3", status: .accepted),
            figureId: figureId, figureTitle: title, cells: cells)
        XCTAssertFalse(suggestion.reopensAnAccept)
        XCTAssertEqual(suggestion.revertDisabledReason, FigureRowGate.revertInTheTable)
    }

    // MARK: - The queue's sections (fix round 1, I1)

    private func figureNote(_ id: String) -> ProjectAnnotation {
        ProjectAnnotation(docId: id, annotation: Annotation(
            id: "n-\(id)", kind: .comment, paragraphId: nil, body: "x", suggestedText: nil,
            priorText: nil, createdAt: Date(timeIntervalSince1970: 0), createdBySession: nil,
            status: .open, userResponse: nil, resolvedAt: nil, isStale: false))
    }

    /// A piece whose only notes are on its own table still has a section —
    /// the board's count click-through lands on it — with the figure's
    /// section right after it, inside its group; only a whole-book figure
    /// goes under "Figures".
    func test_aPiecesFigureFollowsItsPiece_andOnlyWholeBookFiguresGoUnderFigures() {
        let structure = [
            StructureItem(id: "grp-1", title: "Part", type: .group, children: [
                StructureItem(id: "doc-a", title: "A", type: .document, path: "a.md"),
                StructureItem(id: "doc-b", title: "B", type: .document, path: "b.md"),
            ]),
        ]
        let owned = FigureRecord(id: "fig-aaaa1111", name: "cash", kind: .table, piece: "doc-a", path: "figures/cash.csv")
        let book = FigureRecord(id: "fig-bbbb2222", name: "ledger", kind: .table, piece: nil, path: "figures/ledger.csv")
        let orphan = FigureRecord(id: "fig-cccc3333", name: "old", kind: .table, piece: "doc-gone", path: "figures/old.csv")
        let sections = AnnotationScopeSections.build(
            rows: ReviewBoardRows.derive(structure: structure),
            annotations: [figureNote(owned.id), figureNote(book.id), figureNote(orphan.id)],
            figures: [owned, book, orphan])
        XCTAssertEqual(sections.map(\.id),
                       ["grp-1", "doc-a", owned.id, AnnotationScopeSections.figuresHeaderId, book.id, orphan.id])
        XCTAssertEqual(sections[1].annotations, [], "the piece's own section, empty, is the count's landing place")
        XCTAssertEqual(sections[2].title, "Table: cash")
        XCTAssertEqual(sections[2].annotations.map(\.id), ["n-\(owned.id)"])
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

    private func verbs(_ store: ProjectStore, _ documentStore: DocumentStore, undo: UndoManager) -> AnnotationsPaneVerbs {
        AnnotationsPaneVerbs(
            store: store, documentStore: documentStore, world: nil,
            userPreferences: UserPreferences(defaults: UserDefaults(suiteName: "fignote-\(UUID().uuidString)")!),
            undoManager: undo, onChoiceOfferChanged: { _ in },
            projectSnapshot: { store.listAnnotationsAcrossProject() },
            visibleAnnotations: { _ in [] }, effectiveSelection: { _ in [] },
            staleConfirm: .constant(nil), anchorLostNotice: .constant(nil),
            revertConfirm: .constant(nil), rulingNotice: .constant(nil),
            ledgerNotice: .constant(nil), choiceOffer: .constant(nil),
            stetFlourishIds: .constant([]), bulkInFlight: .constant(false),
            selectedIds: .constant([]), bulkNotice: .constant(nil),
            letterLedgerRevision: .constant(0), projectRefreshToken: .constant(0))
    }

    /// **Through the queue's own verb** (fix round 1, M9): a reply on a figure
    /// no grid holds lands with no ⌘Z registered, and the row's Reopen takes
    /// it back (I2: a status-only revert, no cell moved); with the grid open,
    /// the reply's ⌘Z is registered and reopens it.
    func test_theQueuesReplyTakesUndoOnlyOnAHeldFigure_andReopenTakesItBack() async throws {
        let (store, projectStore, figure) = try await openBook()
        let q = try await query(on: figure, store: store)
        let first = await projectStore.figureNotes(figure.id).first
        let ann = try XCTUnwrap(first)
        let um = UndoManager()
        let queue = verbs(projectStore, store, undo: um)

        await queue.figureAccept(figure.id, ann, reply: "The census").value
        let afterReply = await projectStore.figureNotes(figure.id)
        XCTAssertEqual(afterReply.first?.status, .accepted)
        XCTAssertFalse(um.canUndo, "a lent host's act takes no ⌘Z — it would decline on a closed host")

        await queue.figureReopen(figure.id, ann).value
        var notes = await projectStore.figureNotes(figure.id)
        XCTAssertEqual(notes.first?.status, .open, "Reopen from the row takes the reply back")
        let ops = await projectStore.figureOps(figure.id).filter { $0.provenance?.sourceAnnotationId == q.opId }
        XCTAssertEqual(ops.last?.kind, .claudeAcceptRevert)
        XCTAssertNil(ops.last?.figure, "no cell moved")

        let host = try await store.openFigure(figureId: figure.id)
        await queue.figureAccept(figure.id, ann, reply: "Again").value
        XCTAssertTrue(um.canUndo, "the window holds the figure: the reply's ⌘Z is registered")
        um.undo()
        await host.awaitPendingUndoWork()
        notes = await projectStore.figureNotes(figure.id)
        XCTAssertEqual(notes.first?.status, .open)
        await store.closeFigure(figureId: figure.id)
    }

    /// A refused answer is a sentence the writer is told (a deleted note's
    /// typed refusal), never swallowed.
    func test_aRefusedAnswerIsSaid() async throws {
        let (store, _, _) = try await openBook()
        let sentence = AnnotationsPane.sayRefused(FigureNoteError.withdrawn, projectURL: store.projectURL)
        XCTAssertEqual(sentence, "That note was deleted.")
    }
}
