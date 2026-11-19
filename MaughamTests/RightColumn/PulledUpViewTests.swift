import XCTest
import AppKit
import SwiftUI
import MaughamCore
@testable import Maugham

/// **The pulled-up view** (shell plan 3 Task 7): what it draws for each kind
/// under Lock, a posture and "the centre's cover holds it", what Open in
/// Centre does, and — mounted, as measurements only (tripwire 33) — that a
/// pulled-up note is a second editor, that Lock reaches it, that a pulled-up
/// statement and the centre's cover never both bind, and that it fits the
/// column.
@MainActor
final class PulledUpViewTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        FontWarmup.ensure()
    }

    private var fixtures: [StatementMountFixture] = []

    override func tearDown() async throws {
        for fixture in fixtures { fixture.tearDown() }
        fixtures.removeAll()
        try await super.tearDown()
    }

    private func fixture(_ name: String) async throws -> StatementMountFixture {
        let made = try await StatementMountFixture.novel(named: name)
        fixtures.append(made)
        return made
    }

    private let structure: [StructureItem] = [
        StructureItem(id: "ch-1", title: "One", type: .document, path: "one.md"),
        StructureItem(id: "ch-2", title: "Two", type: .document, path: "two.md"),
    ]

    private let onAPiece = WindowSubject(open: .item("ch-1"), faces: .item("ch-1"))

    private func face(_ pulled: PulledUp, isLocked: Bool = false, centreItem: CentreItem? = nil,
                      card: PulledUpView.CanvasCardRead? = nil) -> PulledUpView.Face {
        var subject = onAPiece
        subject.beside = pulled
        return PulledUpView.face(of: pulled, subject: subject, isLocked: isLocked,
                                 centreItem: centreItem, card: card)
    }

    // MARK: - What each kind draws (pure)

    func test_aPulledUpPaletteCardFollowsLock() {
        // A palette card is a research item: the inspector's preview asks
        // `PaletteCardSurface` with the pulled-up thing's own Lock answer.
        XCTAssertEqual(face(.research("card-1"), isLocked: true),
                       .research(id: "card-1", readOnly: true, preview: true))
        XCTAssertEqual(PaletteCardSurface.of(readOnly: PulledUp.research("card-1").refusesEdits(isLocked: true)),
                       .read, "locked: the read host, never the editor")
        XCTAssertEqual(face(.research("card-1"), isLocked: false),
                       .research(id: "card-1", readOnly: false, preview: true))
        XCTAssertEqual(PaletteCardSurface.of(readOnly: PulledUp.research("card-1").refusesEdits(isLocked: false)),
                       .edit, "control: unlocked, the card edits beside")
        // The arm asks exactly the route the centre's card asks.
        let code = try? SourceTree.read("Maugham/Views/PulledUpView.swift")
        XCTAssertTrue(code?.contains("ResearchSubjectInspector(") == true)
        XCTAssertTrue(code?.contains("editsNotes: true") == true)
    }

    func test_aMissingCanvasCardSaysSoAndCloses() {
        let gone = PulledUp.canvasScrap(nodeId: "n-gone")
        let empty = CanvasScene()
        XCTAssertEqual(PulledUpView.read(gone, scene: empty, scraps: [:]), .missing)
        XCTAssertEqual(PulledUpView.read(.canvasPhoto(path: "canvas_assets/a.png"), scene: empty, scraps: [:]),
                       .missing)
        XCTAssertFalse(PulledUpView.cardIsOnTheCanvas(gone, scene: empty))
        XCTAssertEqual(face(gone, card: .missing), .missingCard)
        XCTAssertEqual(PulledUpView.missingCardLine, "This card is no longer on the canvas.")
        // Close puts it away, and nothing else moves.
        var subject = onAPiece
        subject.beside = gone
        let closed = ProjectWindow.closingBeside(subject)
        XCTAssertNil(closed.beside)
        XCTAssertEqual(closed.open, subject.open)
        // The sweep drops it too (a relaunch, a manifest change).
        let swept = ProjectWindow.validatedSubject(
            subject, structure: structure, research: [], figures: [], parked: [],
            editionLanguages: [], canvasCardExists: { PulledUpView.cardIsOnTheCanvas($0, scene: empty) })
        XCTAssertNil(swept.beside, "a gone card is not restored")
        let kept = ProjectWindow.validatedSubject(
            subject, structure: structure, research: [], figures: [], parked: [],
            editionLanguages: [], canvasCardExists: { _ in true })
        XCTAssertEqual(kept.beside, gone, "control: a card still on the canvas is kept")
        XCTAssertEqual(subject.validated(structure: structure, researchIDs: [], figureIDs: [],
                                         editionLanguages: [],
                                         canvasCardExists: { _ in false }).open,
                       subject.open, "only the card goes")
    }

    /// The canvas card beside is READ-ONLY: its words drawn as text, never an
    /// editor on the canvas's shared text storage (tripwires 26–28).
    func test_aPulledUpCanvasCardMountsNoEditor() throws {
        XCTAssertEqual(face(.canvasScrap(nodeId: "n1"), card: .scrap(text: "Gulls at noon.")),
                       .canvasScrap(text: "Gulls at noon."))
        XCTAssertFalse(PulledUp.canvasScrap(nodeId: "n1").isEditableBeside)
        let code = try SourceTree.read("Maugham/Views/PulledUpView.swift")
            .components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//")
                && !$0.trimmingCharacters(in: .whitespaces).hasPrefix("///") }
            .joined(separator: "\n")
        for editor in ["EditorSurface(", "ScrapEditorHost(", "TextEditor(", "NSTextView",
                       "textStorage", "ScrapLayout", "mutateFromInspector"] {
            XCTAssertFalse(code.contains(editor), "the pulled-up view names \(editor)")
        }
        XCTAssertFalse(TripwireGrepTests.editorSurfaceMountSites.contains("PulledUpView.swift"))
    }

    func test_historyPullsUpForAClosedPiece() {
        // Whether or not the piece is open in the centre: History reads the
        // piece's log, never its Document (`HistoryPane`'s optional read).
        for open in [BinderSubject.item("ch-1"), .canvas, .project] {
            var subject = WindowSubject(open: open, faces: open)
            subject.beside = .history(docId: "ch-2")
            XCTAssertEqual(PulledUpView.face(of: .history(docId: "ch-2"), subject: subject, isLocked: false,
                                             centreItem: nil, card: nil),
                           .history(docId: "ch-2"))
            XCTAssertTrue(ProjectWindow.pulledUpIsShownBeside(subject: subject),
                          "the column shows it, whatever the centre")
        }
        XCTAssertEqual(face(.history(docId: "ch-2"), centreItem: .history(docId: "ch-2")),
                       .historyInTheCentre(docId: "ch-2"), "the cover shows it: no second copy")
        let code = try? SourceTree.read("Maugham/Views/PulledUpView.swift")
        XCTAssertTrue(code?.contains("activeDocId: docId,") == true)
    }

    func test_aPulledUpStatementInTheCentreDrawsThePlaceholder() {
        for (pulled, kind) in [(PulledUp.lessons, Statement.Kind.lessons),
                               (.firstReader, .firstReader), (.visualLanguage, .visualLanguage)] {
            XCTAssertEqual(face(pulled, centreItem: .statement(kind: kind, scope: .project)),
                           .statementInTheCentre(kind))
            XCTAssertEqual(face(pulled), .statement(kind), "control: nothing in the centre, its own host")
            XCTAssertEqual(face(pulled, centreItem: .statement(kind: .intent, scope: .project)),
                           .statement(kind), "another statement in the centre is not this one")
            XCTAssertEqual(face(pulled, isLocked: true), .statement(kind),
                           "Lock is not a statement's; its posture is, inside StatementPane")
        }
    }

    func test_everyPulledUpKindHasOpenInCentre() {
        let kinds: [PulledUp] = [.research("r1"), .figure("f1"), .canvasScrap(nodeId: "n1"),
                                 .canvasPhoto(path: "canvas_assets/a.png"), .lessons, .firstReader,
                                 .visualLanguage, .history(docId: "ch-2")]
        for pulled in kinds {
            var subject = onAPiece
            subject.beside = pulled
            let opening = PulledUpView.opening(pulled, subject: subject, structure: structure,
                                               projectType: .novel,
                                               photoNode: { _ in CanvasNodeID("photo-node") })
            switch pulled {
            case .research(let id):
                guard case .subject(let next) = opening else { return XCTFail("\(pulled)") }
                XCTAssertEqual(next.open, .research(id))
                XCTAssertNil(next.beside, "it leaves the pulled-up position")
            case .figure(let id):
                guard case .subject(let next) = opening else { return XCTFail("\(pulled)") }
                XCTAssertEqual(next.open, .figure(id))
            case .canvasScrap(let nodeId):
                guard case .canvas(let next, let node) = opening else { return XCTFail("\(pulled)") }
                XCTAssertEqual(next.open, .canvas, "the canvas opens")
                XCTAssertEqual(node, CanvasNodeID(nodeId), "and selects the card")
                XCTAssertNil(next.beside)
            case .canvasPhoto:
                guard case .canvas(let next, let node) = opening else { return XCTFail("\(pulled)") }
                XCTAssertEqual(next.open, .canvas)
                XCTAssertEqual(node, CanvasNodeID("photo-node"))
            case .lessons, .firstReader, .visualLanguage, .history:
                XCTAssertEqual(opening, pulled.centreItem.map(PulledUpView.Opening.centreItem),
                               "the centre's cover")
                XCTAssertNotNil(pulled.centreItem)
            }
        }
    }

    /// Open in Centre on a pulled-up card SELECTS it on the canvas: at once
    /// while the canvas is attached, else once `load()` takes the parked
    /// reveal against the attached scene — and never a card the scene lacks.
    func test_openInCentreSelectsTheCardOnTheCanvas() throws {
        let root = TestTemp.root.appendingPathComponent("pulled-up-reveal-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let card = CanvasNodeID("n-1")
        func withCard(_ m: CanvasModel) {
            m.withScene(persist: false) {
                $0.insert(CanvasNode(id: card, kind: .scrap, origin: .zero, width: 240, cachedHeight: 80))
            }
        }

        let live = CanvasModel()
        live.attach(projectRoot: root)
        withCard(live)
        live.revealAndSelect(card)
        XCTAssertEqual(live.selection, .node(card), "an attached canvas selects at once")

        let closed = CanvasModel()
        closed.revealAndSelect(card)
        XCTAssertNil(closed.selection, "nothing is selected against a scene not yet attached")
        closed.attach(projectRoot: root)
        withCard(closed)
        XCTAssertEqual(closed.takePendingReveal(), .node(card), "the canvas's load takes the reveal")
        XCTAssertEqual(closed.selection, .node(card), "and the card is selected with it")

        let gone = CanvasModel()
        gone.attach(projectRoot: root)
        gone.revealAndSelect(CanvasNodeID("n-gone"))
        XCTAssertNil(gone.selection, "a card the scene lacks is never selected")
    }

    // MARK: - Mounted measurements

    func test_aPulledUpNoteIsASecondEditor() async throws {
        let f = try await fixture("PulledUpNote")
        let note = try await f.store.addResearchTextNote(parentId: nil, title: "Tides")
        let window = f.hostView(view(f, pulled: .research(note.id), isLocked: false), width: 360)
        await pumpUntil(deadline: 5) { f.firstTextView(in: window) != nil }
        let editor = try XCTUnwrap(f.firstTextView(in: window), "the note's editor mounted beside")
        XCTAssertTrue(editor.usesPrivateUndoManager,
                      "a second editor in its window: its own undo stack, none of the window's commands")
        XCTAssertEqual(f.allTextViews(in: window).count, 1)
    }

    func test_aPulledUpNoteIsReadOnlyUnderLock() async throws {
        let f = try await fixture("PulledUpNoteLocked")
        let note = try await f.store.addResearchTextNote(parentId: nil, title: "Tides")
        let locked = f.hostView(view(f, pulled: .research(note.id), isLocked: true), width: 360)
        await pumpUntil(deadline: 5) { f.firstTextView(in: locked) != nil }
        let lockedEditor = try XCTUnwrap(f.firstTextView(in: locked))
        await waitOut(0.2)
        XCTAssertFalse(lockedEditor.shouldChangeText(in: NSRange(location: 0, length: 0),
                                                     replacementString: "x"),
                       "Lock reaches the note pulled up, as it does in the centre")

        let open = f.hostView(view(f, pulled: .research(note.id), isLocked: false), width: 360)
        await pumpUntil(deadline: 5) { f.firstTextView(in: open) != nil }
        let openEditor = try XCTUnwrap(f.firstTextView(in: open))
        await waitOut(0.2)
        XCTAssertTrue(openEditor.shouldChangeText(in: NSRange(location: 0, length: 0),
                                                  replacementString: "x"),
                      "control: unlocked, the note takes typing")
    }

    /// **One statement, one host** (Review Focus 3): What I've Learned pulled
    /// up while the centre's cover holds it — the cover binds, the pulled-up
    /// view reads the placeholder, and never a second editor.
    func test_aPulledUpStatementAndTheCentreCoverNeverBothBind() async throws {
        let f = try await fixture("PulledUpLessonsTwice")
        let statement = try await f.store.createStatement(kind: .lessons, scope: .project)
        try await f.store.mutateStatementText(of: statement, session: "pulled-up-test") { _ in
            "I overwrite endings."
        }
        let lessons = CentreItem.statement(kind: .lessons, scope: .project)
        let window = f.hostView(AnyView(HStack(spacing: 0) {
            CentreItemCover(store: f.store, documentStore: f.documentStore, item: lessons,
                            bible: nil, world: nil, window: nil, findIsUp: false, onClose: {})
                .frame(width: 400)
            view(f, pulled: .lessons, isLocked: false, centreItem: lessons)
                .frame(width: 300)
        }), width: 700)
        await pumpUntil(deadline: 5) { f.store.openStatementDocument(id: statement.id) != nil }
        await waitOut(0.5)
        XCTAssertEqual(f.allTextViews(in: window).count, 1, "exactly one host binds the ledger")
        let editor = try XCTUnwrap(f.firstTextView(in: window))
        XCTAssertLessThan(CentreKeysView.visibleFrame(of: editor).midX, 400,
                          "the cover's host holds it; the pulled-up view reads")
        XCTAssertTrue(try f.allStaticTexts(in: window).contains(GoingForView.inTheCentreLine))

        // Control: with nothing in the centre, the pulled-up view is the host.
        let g = try await fixture("PulledUpLessonsAlone")
        let alone = try await g.store.createStatement(kind: .lessons, scope: .project)
        let solo = g.hostView(view(g, pulled: .lessons, isLocked: false), width: 320)
        await pumpUntil(deadline: 5) { g.store.openStatementDocument(id: alone.id) != nil }
        await pumpUntil(deadline: 5) { g.firstTextView(in: solo) != nil }
        XCTAssertEqual(g.allTextViews(in: solo).count, 1, "control: the pulled-up statement edits")
    }

    /// Review Focus 5: a 200-character title at the column's floor — the
    /// header fits, the title truncating in the middle.
    func test_theTitleTruncatesInTheMiddle() throws {
        let title = String(repeating: "A very long research note title ", count: 7).prefix(200)
        for width: CGFloat in [240, 360, 480] {
            let pane = width - RightColumn.resizeHandleWidth
            let header = NSHostingController(rootView: BesideHeader(
                title: String(title), openInCentre: {}, close: {}))
            let size = header.sizeThatFits(in: CGSize(width: pane, height: 200))
            XCTAssertLessThanOrEqual(size.width, pane + 0.5, "the header fits a \(width)pt column")
        }
        let code = try SourceTree.read("Maugham/Views/PulledUpView.swift")
        let header = try XCTUnwrap(code.range(of: "struct BesideHeader: View {"))
        let body = String(code[header.lowerBound...])
        XCTAssertTrue(body.contains(".truncationMode(.middle)"), "the middle goes, not the end")
        XCTAssertTrue(body.contains(".help(title)"), "the whole title is its tooltip")
    }

    func test_thePulledUpViewFitsTheColumn() async throws {
        let f = try await fixture("PulledUpWidth")
        for width: CGFloat in [240, 480] {
            let pane = width - RightColumn.resizeHandleWidth
            let hosted = NSHostingController(rootView: view(f, pulled: .canvasScrap(nodeId: "gone"),
                                                            isLocked: true))
            let size = hosted.sizeThatFits(in: CGSize(width: pane, height: 700))
            XCTAssertLessThanOrEqual(size.width, pane + 0.5, "the pulled-up view fits a \(width)pt column")
        }
    }

    // MARK: - Helpers

    private func view(_ f: StatementMountFixture, pulled: PulledUp, isLocked: Bool,
                      centreItem: CentreItem? = nil) -> AnyView {
        var subject = onAPiece
        subject.beside = pulled
        return AnyView(PulledUpView(
            store: f.store, documentStore: f.documentStore,
            subject: .constant(subject), centreItem: centreItem,
            canvasModel: CanvasModel(), editorControl: EditorControl(),
            figureListing: FigureListingModel(), figureGridPresence: FigureGridPresence(),
            figureWindows: nil, window: nil, isLocked: isLocked, figureTree: nil,
            bible: nil, world: nil, onOpenInCentre: { _ in })
            .environment(f.preferences))
    }
}
