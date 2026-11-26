import XCTest
import MaughamCore
@testable import Maugham

/// **What the writer types in is `open`; what the right column is about is
/// `faces`** — and after a Brief link or ⌘⌥K the two differ (shell closing
/// A1–A3, the milestone review's I1/I2/M1). Every act about the text being
/// typed reads the open piece: the checkpoint keys (⌘S, ⇧⌘S), ⌘⌥C, the line
/// above the prose and its drift mark, the syntax sheet. Each pin here builds
/// a subject whose faces are elsewhere and asserts the open piece answers.
/// The census that keeps new readers honest is
/// `FacesReaderCensusTests.test_theFacesAreReadOnlyByTheirNamedConsumers`.
@MainActor
final class TheOpenPieceNotTheFacesTests: XCTestCase {

    private let structure: [StructureItem] = [
        StructureItem(id: "ch-a", title: "Arrival", type: .document, path: "manuscript/01-arrival.md"),
        StructureItem(id: "ch-b", title: "Burial", type: .document, path: "manuscript/02-burial.md"),
        StructureItem(id: "sc-c", title: "Coda", type: .document, path: "manuscript/03-coda.fountain"),
    ]

    /// Every way the faces leave the open piece: another piece's Brief, the
    /// Book's, an edition's (⌘⌥K), the Canvas.
    private func facesElsewhere(than open: String) -> [WindowSubject] {
        [BinderSubject.item(open == "ch-b" ? "ch-a" : "ch-b"), .project,
         .edition(language: "sr"), .canvas]
            .map { WindowSubject(open: .item(open), faces: $0) }
    }

    // MARK: - A1: the checkpoint keys

    /// ⌘S and ⇧⌘S flush, breadcrumb and ask the posture of the OPEN piece.
    func test_theCheckpointTargetIsTheOpenPiece() {
        for subject in facesElsewhere(than: "ch-a") {
            XCTAssertEqual(CheckpointTarget.of(subject, structure: structure),
                           CheckpointTarget(docId: "ch-a", path: "manuscript/01-arrival.md"),
                           "faces on \(subject.faces)")
        }
        // Control: nothing open in the structure names no document.
        XCTAssertEqual(
            CheckpointTarget.of(WindowSubject(open: .canvas, faces: .item("ch-b")), structure: structure),
            CheckpointTarget(docId: BinderSubject.noDocumentSubject, path: nil),
            "the Canvas open: no piece is being typed, so no breadcrumb")
    }

    /// **A Collection whose faces are on another author's piece still
    /// checkpoints the open piece** — the posture asked is the open piece's,
    /// so the writer's own checkpoint lands, with its breadcrumb on the open
    /// piece's stream, and the flash it shows is over a written checkpoint.
    func test_aForeignPieceOnTheFacesDoesNotRefuseTheOpenPiecesCheckpoint() async throws {
        let project = TestTemp.root.appendingPathComponent("open-not-faces-\(UUID())")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: project) }
        let seed = Op(opId: ULID.generate(), docId: "ch-a", at: Date(), device: "m", session: "s",
                      kind: .typingBurst, changes: [.init(paragraphId: "aaaa", prior: nil, next: "Mine.")])
        try await OpLogStore(projectURL: project).append(seed)

        let theirs = Posture(LocalWritePermit(permit: .reviewer, actor: .author,
                                              documentClass: .piece("ch-b")))
        XCTAssertFalse(theirs.allows(.checkpoint), "premise: the other author's piece refuses")
        let subject = WindowSubject(open: .item("ch-a"), faces: .item("ch-b"))
        let target = CheckpointTarget.of(subject, structure: structure)

        var flashed = false
        await CheckpointFlashDecision.run(projectURL: project, onSuccess: { flashed = true }) {
            _ = try await CheckpointCapture.run(
                projectURL: project, activeDocId: target.docId, allDocIds: ["ch-a", "ch-b"],
                figureIds: [], device: "m", session: "s", label: nil, activeDocument: nil,
                posture: { $0 == "ch-b" ? theirs : .author })
        }

        XCTAssertTrue(flashed)
        let opsA = try await OpLogStore(projectURL: project).load(docId: "ch-a")
        XCTAssertEqual(opsA.last?.kind, .checkpoint, "the breadcrumb is on the open piece")
        let entries = await CheckpointStore(projectURL: project).load().checkpoints
        XCTAssertEqual(entries.count, 1, "the flash is over a written checkpoint")
        XCTAssertEqual(entries.first?.activeDoc, "ch-a")
    }

    // MARK: - A2: the line above the prose

    /// The strip and its drift mark name the open piece's stream, whatever
    /// the faces are on — another piece, the Book, an edition (⌘⌥K).
    func test_theStripIsAboutTheOpenPiece() {
        for subject in facesElsewhere(than: "ch-a") {
            XCTAssertEqual(IntentStrip.docId(of: subject), "ch-a", "faces on \(subject.faces)")
        }
    }

    /// Against a real project: with the faces on the Book or an edition, the
    /// strip over the open chapter quotes the CHAPTER's line, not the Book's.
    func test_theStripQuotesTheOpenPiecesLineWithTheFacesOnTheBookOrAnEdition() async throws {
        let fixture = try await StatementMountFixture.novel(named: "strip-open")
        addTeardownBlock { await fixture.closeAndTearDown() }
        let chapter = fixture.documentItemId
        try await fixture.store.updateInspector(id: chapter, synopsis: "The chapter’s own line.")
        _ = try await fixture.store.createStatement(kind: .intent, scope: .project)
        let book = try XCTUnwrap(fixture.store.statement(kind: .intent, scope: .project))
        try await fixture.store.mutateStatementText(of: book, session: "s") { markdown in
            StatementEssay.recomposed(essay: "The Book’s line.", into: markdown)
        }

        for faces in [BinderSubject.project, .edition(language: "sr")] {
            XCTAssertEqual(
                IntentStrip.line(store: fixture.store,
                                 subject: WindowSubject(open: .item(chapter), faces: faces),
                                 isNoChromeOn: false),
                "The chapter’s own line.", "faces on \(faces)")
        }
        // Control: the Book open shows no strip at all.
        XCTAssertNil(IntentStrip.line(store: fixture.store, subject: .book, isNoChromeOn: false))
    }

    // MARK: - A3: the syntax sheet

    /// ⌘/ opens on the open piece's format: a script open in a Collection
    /// with the faces on a prose piece opens on Fountain.
    func test_theSyntaxSheetOpensOnTheOpenPiecesFormat() {
        let subject = WindowSubject(open: .item("sc-c"), faces: .item("ch-a"))
        XCTAssertEqual(ProjectWindow.syntaxHelpFormat(subject: subject, type: .collection,
                                                      structure: structure), .fountain)
        XCTAssertEqual(ProjectWindow.syntaxHelpFormat(
            subject: WindowSubject(open: .item("ch-a"), faces: .item("sc-c")), type: .collection,
            structure: structure), .markdown, "control: prose open, a script on the faces")
    }
}
