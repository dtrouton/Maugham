import XCTest
import AppKit
import SwiftUI
import Observation
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
        for fixture in fixtures { await fixture.closeAndTearDown() }
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
                      card: PulledUpView.CanvasCardRead? = nil,
                      open: BinderSubject? = nil, wallCard: String? = nil) -> PulledUpView.Face {
        var subject = open.map { WindowSubject(open: $0, faces: $0) } ?? onAPiece
        subject.beside = pulled
        return PulledUpView.face(
            of: pulled,
            centre: .init(subject: subject, centreItem: centreItem, paletteWallCard: wallCard),
            isLocked: isLocked, card: card)
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
        XCTAssertEqual(PulledUpView.read(.canvasPhoto(path: "canvas_assets/a.png"), scene: empty,
                                         scraps: [:]), .missing)
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
            XCTAssertEqual(face(.history(docId: "ch-2"), open: open), .history(docId: "ch-2"))
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
                                 .canvasPhoto(path: "canvas_assets/a.png"), .canvasRegion(id: "rg-1"),
                                 .lessons, .firstReader, .visualLanguage, .history(docId: "ch-2")]
        for pulled in kinds {
            var subject = onAPiece
            subject.beside = pulled
            let opening = PulledUpView.opening(pulled, subject: subject, structure: structure,
                                               projectType: .novel,
                                               photoNode: { _ in CanvasNodeID("photo-node") })
            // Every kind is checked; a wrong case is recorded, never a return.
            switch (pulled, opening) {
            case (.research(let id), .subject(let next)):
                XCTAssertEqual(next.open, .research(id))
                XCTAssertNil(next.beside, "it leaves the pulled-up position")
            case (.figure(let id), .subject(let next)):
                XCTAssertEqual(next.open, .figure(id))
                XCTAssertNil(next.beside)
            case (.canvasScrap(let nodeId), .canvas(let next, let node)):
                XCTAssertEqual(next.open, .canvas, "the canvas opens")
                XCTAssertEqual(node, .node(CanvasNodeID(nodeId)), "and selects the card")
                XCTAssertNil(next.beside)
            case (.canvasPhoto, .canvas(let next, let node)):
                XCTAssertEqual(next.open, .canvas)
                XCTAssertEqual(node, .node(CanvasNodeID("photo-node")))
                XCTAssertNil(next.beside)
            case (.canvasRegion(let id), .canvas(let next, let target)):
                XCTAssertEqual(next.open, .canvas, "the canvas opens")
                XCTAssertEqual(target, .region(CanvasRegionID(id)), "and selects the region")
                XCTAssertNil(next.beside, "it leaves the pulled-up position")
            case (.lessons, .centreItem(let item)), (.firstReader, .centreItem(let item)),
                 (.visualLanguage, .centreItem(let item)), (.history, .centreItem(let item)):
                XCTAssertEqual(item, pulled.centreItem, "the centre's cover")
                // The window's verb moves it: the pulled-up position empties.
                XCTAssertNil(ProjectWindow.openingInCentre(item, subject: subject).beside,
                             "\(pulled) moves to the centre")
            default:
                XCTFail("\(pulled) opened as \(opening)")
            }
        }
    }

    /// **Never a second editor on the item the centre shows** — one rule
    /// (`PulledUpView.centreShows`), every kind.
    func test_whereTheCentreShowsItThePulledUpViewNeverEdits() {
        // A research note open in the centre: its panel only, read-only.
        XCTAssertEqual(face(.research("r1"), open: .research("r1")),
                       .research(id: "r1", readOnly: true, preview: false))
        // A palette card on the wall: the read host beside, never the editor.
        XCTAssertEqual(face(.research("card-1"), open: .palette, wallCard: "card-1"),
                       .research(id: "card-1", readOnly: true, preview: true))
        XCTAssertEqual(PaletteCardSurface.of(readOnly: true), .read)
        XCTAssertEqual(face(.research("card-1"), open: .palette, wallCard: "card-2"),
                       .research(id: "card-1", readOnly: false, preview: true),
                       "control: the wall shows another card")
        XCTAssertEqual(face(.research("card-1"), wallCard: "card-1"),
                       .research(id: "card-1", readOnly: false, preview: true),
                       "control: a remembered wall card with the wall closed")
        // A figure in the centre: its inspector, not a second surface.
        XCTAssertEqual(face(.figure("f1"), open: .figure("f1")), .figure(id: "f1", surface: false))
        XCTAssertEqual(face(.figure("f1")), .figure(id: "f1", surface: true), "control")
        // A canvas card is read-only words beside whatever the canvas has
        // selected: no second editor to refuse, so the rule never names it.
        XCTAssertFalse(PulledUpView.centreShows(.canvasScrap(nodeId: "n1"),
                                                centre: .init(subject: WindowSubject(open: .canvas, faces: .canvas))))
        XCTAssertEqual(face(.canvasScrap(nodeId: "n1"), card: .scrap(text: "Gulls"), open: .canvas),
                       .canvasScrap(text: "Gulls"))
        // A statement or History in the cover: the line, never an editor.
        XCTAssertEqual(face(.lessons, centreItem: .statement(kind: .lessons, scope: .project)),
                       .statementInTheCentre(.lessons))
        XCTAssertEqual(face(.history(docId: "ch-1"), centreItem: .history(docId: "ch-1")),
                       .historyInTheCentre(docId: "ch-1"))
    }

    /// The scrap beside follows the writer's typing on the attached canvas
    /// through the model's observable `scraps` — no scene revision needed,
    /// and no editor on the shared storage.
    func test_aPulledUpScrapFollowsTheTypingOnTheCanvas() throws {
        let root = TestTemp.root.appendingPathComponent("pulled-up-live-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let id = CanvasNodeID("n-1")
        let model = CanvasModel()
        model.attach(projectRoot: root)
        model.withScene(persist: false) {
            $0.insert(CanvasNode(id: id, kind: .scrap, origin: .zero, width: 240, cachedHeight: 80))
        }
        model.setScrapText("Gulls", for: id)
        let read = PulledUpView.CanvasCardRead.scrap(text: "Gulls")
        let revision = model.sceneRevision
        model.setScrapText("Gulls at noon", for: id)
        XCTAssertEqual(PulledUpView.liveCard(read, pulled: .canvasScrap(nodeId: "n-1"), model: model),
                       .scrap(text: "Gulls at noon"))
        XCTAssertEqual(model.sceneRevision, revision, "premise: typing moves no scene revision")
        // A closed canvas: the task's read of the sidecar stands.
        let closed = CanvasModel()
        XCTAssertEqual(PulledUpView.liveCard(read, pulled: .canvasScrap(nodeId: "n-1"), model: closed), read)
        XCTAssertEqual(PulledUpView.liveCard(.missing, pulled: .canvasScrap(nodeId: "n-1"), model: model),
                       .missing, "a card gone from the scene stays gone")
        let code = try SourceTree.read("Maugham/Views/PulledUpView.swift")
        XCTAssertTrue(code.contains("let card = Self.liveCard(card, pulled: pulled, model: canvasModel)"),
                      "the body draws the live words")
    }

    /// **Open in Centre moves every kind to the centre** (controller ruling):
    /// the pulled-up position empties, through the click rule's open-in-centre
    /// and the centre item's path alike; closing the centre item does not pull
    /// it back up.
    func test_openInCentreMovesEveryKindToTheCentre() {
        for pulled in [PulledUp.research("r1"), .figure("f1"), .canvasScrap(nodeId: "n1"),
                       .lessons, .firstReader, .visualLanguage, .history(docId: "ch-1")] {
            var subject = onAPiece
            subject.beside = pulled
            let viaClickRule = ProjectWindow.openingBesideInCentre(subject, structure: structure,
                                                                   projectType: .novel)
            XCTAssertNil(viaClickRule.beside, "\(pulled): the click rule's open-in-centre")
            if let item = pulled.centreItem {
                let opened = ProjectWindow.openingInCentre(item, subject: subject)
                XCTAssertNil(opened.beside, "\(pulled): the centre item's path")
                // Close clears the item; the subject is untouched, so nothing returns.
                XCTAssertNil(ProjectWindow.centreItemAfterOpenChange(item, from: opened.open,
                                                                     to: .item("ch-2")))
                XCTAssertNil(opened.beside, "closing does not pull it back up")
            }
        }
        // Anything else pulled up stays.
        var other = onAPiece
        other.beside = .firstReader
        XCTAssertEqual(ProjectWindow.openingInCentre(.statement(kind: .lessons, scope: .project),
                                                     subject: other).beside, .firstReader)
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

        // A region pulled up: Open in Centre selects the region, now or at load.
        let region = CanvasRegionID("rg-1")
        func withRegion(_ m: CanvasModel) {
            m.withScene(persist: false) {
                $0.insertRegion(CanvasRegion(id: region, label: "Fog",
                                             frame: CGRect(x: 0, y: 0, width: 400, height: 300)))
            }
        }
        let liveRegion = CanvasModel()
        liveRegion.attach(projectRoot: root)
        withRegion(liveRegion)
        liveRegion.revealAndSelect(.region(region))
        XCTAssertEqual(liveRegion.selection, .region(region))
        let closedRegion = CanvasModel()
        closedRegion.revealAndSelect(.region(region))
        XCTAssertNil(closedRegion.selection)
        closedRegion.attach(projectRoot: root)
        withRegion(closedRegion)
        XCTAssertEqual(closedRegion.takePendingReveal(), .region(region))
        XCTAssertEqual(closedRegion.selection, .region(region), "selected when the canvas loads")
        let goneRegion = CanvasModel()
        goneRegion.attach(projectRoot: root)
        goneRegion.revealAndSelect(.region(CanvasRegionID("rg-gone")))
        XCTAssertNil(goneRegion.selection, "a region the scene lacks is never selected")
    }

    // MARK: - A region pulled up (owner, 2026-11-20)

    /// A scene with one region "Fog" holding, out of id order: a scrap low
    /// down, a research note's card at the top, a picture in between; and a
    /// scrap that is not a member.
    private func regionScene() -> (scene: CanvasScene, region: CanvasRegionID,
                                   scraps: [CanvasNodeID: String], items: CanvasItemIndex) {
        var s = CanvasScene()
        let region = CanvasRegionID("rg-1")
        s.insertRegion(CanvasRegion(id: region, label: "Fog",
                                    frame: CGRect(x: 0, y: 0, width: 600, height: 900)))
        let low = CanvasNodeID("a-scrap")
        let note = CanvasNodeID("b-note")
        let picture = CanvasNodeID("c-picture")
        let outside = CanvasNodeID("d-outside")
        s.insert(CanvasNode(id: low, kind: .scrap, origin: CGPoint(x: 0, y: 600),
                            width: 240, cachedHeight: 80))
        s.insert(CanvasNode(id: note, kind: .item(.project(id: "res-note")),
                            origin: CGPoint(x: 0, y: 0), width: 240, cachedHeight: 80))
        s.insert(CanvasNode(id: picture, kind: .item(.owned(path: "canvas_assets/p.png")),
                            origin: CGPoint(x: 0, y: 300), width: 240, cachedHeight: 80))
        s.insert(CanvasNode(id: outside, kind: .scrap, origin: .zero, width: 240, cachedHeight: 80))
        for id in [low, note, picture] { CanvasMembership.join(id, home: region, in: &s) }
        let items = CanvasItemIndex.over(research: [
            ResearchItem(id: "res-note", title: "The falls", type: .asset, kind: .document,
                         path: "research/falls.md")])
        return (s, region, [low: "Low words\nand more", outside: "not a member"], items)
    }

    /// **The region's cards in the canvas's visual order** — the shelf's own
    /// ordering — a scrap as its whole words, a picture as a picture, a
    /// research card as a title row that pulls the item up.
    func test_aPulledUpRegionReadsItsCardsInTheCanvassOrder() {
        let r = regionScene()
        let read = PulledUpRegionView.read(r.region.raw, scene: r.scene, scraps: r.scraps, items: r.items)
        XCTAssertEqual(read, .region(title: "Fog", members: [
            .item(id: "res-note", title: "The falls", glyph: CanvasItemKind.researchNote.glyph,
                  resolves: true),
            .picture(path: "canvas_assets/p.png"),
            .scrap(nodeId: "a-scrap", text: "Low words\nand more"),
        ]), "top to bottom; a non-member is not read")
        guard case .region(_, let members) = read else { return XCTFail("\(read)") }
        let memberOfNode = ["b-note": "item:res-note", "c-picture": "picture:canvas_assets/p.png",
                            "a-scrap": "scrap:a-scrap"]
        XCTAssertEqual(members.map(\.id),
                       PinnedReferences.readingOrder(ofRegion: r.region, in: r.scene)
                           .map { memberOfNode[$0.raw] ?? "?" },
                       "the shelf's one ordering")
        XCTAssertEqual(members[0].pulledUp, .research("res-note"), "a title row pulls its item up")
        XCTAssertNil(members[1].pulledUp, "a picture is drawn, not pulled up")
        XCTAssertNil(members[2].pulledUp, "a scrap is drawn, not pulled up")
        XCTAssertEqual(PulledUpRegionView.title(of: read), "Fog")
        // The title row's click is the click rule's pull-up: the item replaces the region.
        let up = ClickRule.pullUp(.research("res-note"),
                                  current: WindowSubject(open: .item("ch-1"), faces: .item("ch-1"),
                                                         beside: .canvasRegion(id: r.region.raw)))
        XCTAssertEqual(up.beside, .research("res-note"))
        // An item the project no longer holds is a title row that is no control.
        let gone = PulledUpRegionView.read(r.region.raw, scene: r.scene, scraps: r.scraps, items: .empty)
        guard case .region(_, let goneMembers) = gone else { return XCTFail("\(gone)") }
        XCTAssertEqual(goneMembers[0], .item(id: "res-note", title: CanvasItemFacts.missingTitle,
                                             glyph: CanvasItemKind.missingGlyph, resolves: false))
        XCTAssertNil(goneMembers[0].pulledUp)
    }

    /// **A region no longer on the canvas says so, with Close**, as a missing
    /// card does; the sweep puts it away.
    func test_aMissingRegionSaysSoAndCloses() {
        let empty = CanvasScene()
        XCTAssertEqual(PulledUpRegionView.read("rg-gone", scene: empty, scraps: [:], items: .empty),
                       .missing)
        XCTAssertEqual(PulledUpRegionView.title(of: .missing), PulledUpView.canvasRegionTitle)
        XCTAssertEqual(PulledUpRegionView.title(of: nil), PulledUpView.canvasRegionTitle)
        XCTAssertFalse(PulledUpView.cardIsOnTheCanvas(.canvasRegion(id: "rg-gone"), scene: empty))
        XCTAssertTrue(PulledUpView.cardIsOnTheCanvas(.canvasRegion(id: regionScene().region.raw),
                                                     scene: regionScene().scene), "control")
        let code = (try? SourceTree.read("Maugham/Views/PulledUpRegionView.swift")) ?? ""
        XCTAssertTrue(code.contains("Button(BesideHeader.closeLabel, action: close)"),
                      "the missing state offers Close")
    }

    /// **A scrap beside follows the canvas's own typing**, as a pulled-up
    /// scrap does; a closed canvas keeps the task's read.
    func test_aPulledUpRegionsScrapFollowsTheCanvassTyping() throws {
        let r = regionScene()
        let read = PulledUpRegionView.read(r.region.raw, scene: r.scene, scraps: r.scraps, items: r.items)
        let closed = CanvasModel()
        XCTAssertEqual(PulledUpRegionView.live(read, model: closed), read, "no canvas attached: the read")
        let root = TestTemp.root.appendingPathComponent("pulled-up-region-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let live = CanvasModel()
        live.attach(projectRoot: root)
        live.setScrapText("Typed just now", for: CanvasNodeID("a-scrap"))
        guard case .region(_, let members)? = PulledUpRegionView.live(read, model: live) else {
            return XCTFail("a region")
        }
        XCTAssertEqual(members.last, .scrap(nodeId: "a-scrap", text: "Typed just now"))
    }

    /// The region's face and the rules every pulled-up kind shares: never a
    /// second editor, shown beside, Esc and the canvas's cover generic.
    func test_aPulledUpRegionIsReadOnlyBesideAndShownInEveryCentre() {
        let pulled = PulledUp.canvasRegion(id: "rg-1")
        XCTAssertEqual(face(pulled), .canvasRegion(id: "rg-1"))
        XCTAssertEqual(face(pulled, open: .canvas), .canvasRegion(id: "rg-1"))
        XCTAssertFalse(PulledUpView.centreShows(pulled, centre: .init(subject: onAPiece)),
                       "never 'shown by the centre': there is no editor beside to refuse")
        var subject = onAPiece
        subject.beside = pulled
        XCTAssertTrue(ProjectWindow.pulledUpIsShownBeside(subject: subject))
        XCTAssertEqual(RightColumnContent.of(position: .pulledUp, subject: subject,
                                             translationLanguage: nil, structure: structure,
                                             projectType: .novel),
                       .pulledUp(pulled))
        XCTAssertTrue(PulledUpEscapeModifier.claims(pulledUp: pulled, position: .pulledUp,
                                                    showInspector: true, isNoChromeOn: false))
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

    /// **The hand-over, both ways** (review item 4): What I've Learned pulled
    /// up with its editor bound; Open in Centre (the window's path) → the
    /// pulled-up position empties and the cover binds, the pulled-up host
    /// letting go under the gate first (one `Document` at a time); Close →
    /// the cover lets go and nothing is pulled back up.
    func test_aPulledUpStatementMovesToTheCentreAndBack() async throws {
        let f = try await fixture("PulledUpHandOver")
        let statement = try await f.store.createStatement(kind: .lessons, scope: .project)
        try await f.store.mutateStatementText(of: statement, session: "pulled-up-test") { _ in
            "I overwrite endings."
        }
        let probe = PulledUpWindowProbe(subject: {
            var s = onAPiece; s.beside = .lessons; return s
        }())
        let window = f.hostView(AnyView(PulledUpBesideTheCentre(f: f, probe: probe)), width: 740)
        await pumpUntil(deadline: 5) {
            f.store.openStatementDocument(id: statement.id) != nil && f.firstTextView(in: window) != nil
        }
        let first = try XCTUnwrap(f.store.openStatementDocument(id: statement.id),
                                  "premise: the pulled-up statement holds the ledger")
        XCTAssertGreaterThan(CentreKeysView.visibleFrame(of: try f.textView(in: window)).midX, 400,
                             "premise: the editor is the pulled-up one")

        var events: [StatementGateEvent] = []
        f.store.onStatementGateEvent = { events.append($0) }
        defer { f.store.onStatementGateEvent = nil }
        // The window's Open in Centre: `PulledUpView.opening` → `openInCentre`.
        guard case .centreItem(let item) = PulledUpView.opening(
            .lessons, subject: probe.subject, structure: f.store.manifest.structure,
            projectType: f.store.manifest.type, photoNode: { _ in nil }) else {
            return XCTFail("a statement opens as the centre's cover")
        }
        probe.subject = ProjectWindow.openingInCentre(item, subject: probe.subject)
        probe.centreItem = item
        XCTAssertNil(probe.subject.beside, "the pulled-up position empties")
        await pumpUntil(deadline: 5) {
            guard let now = f.store.openStatementDocument(id: statement.id) else { return false }
            return now !== first && f.allTextViews(in: window).count == 1
        }
        let id = statement.id
        let closed = try XCTUnwrap(events.firstIndex(of: .closed(id)), "the pulled-up host let go: \(events)")
        let loading = try XCTUnwrap(events.lastIndex(of: .loading(id)), "the cover loaded: \(events)")
        XCTAssertLessThan(try XCTUnwrap(events.firstIndex(of: .closing(id))), closed)
        XCTAssertLessThan(closed, loading, "never two Documents on the ledger: \(events)")
        XCTAssertTrue(first.isClosed)
        XCTAssertEqual(f.allTextViews(in: window).count, 1)
        XCTAssertLessThan(CentreKeysView.visibleFrame(of: try f.textView(in: window)).midX, 400,
                          "the one editor is the cover's")

        // Close: the cover lets go; nothing returns to the pulled-up position.
        probe.centreItem = nil
        await pumpUntil(deadline: 5) { f.store.openStatementDocument(id: statement.id) == nil }
        await waitOut(0.3)
        XCTAssertNil(probe.subject.beside)
        XCTAssertTrue(f.allTextViews(in: window).isEmpty, "no editor left anywhere")
        XCTAssertNil(f.store.openStatementDocument(id: statement.id))
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

/// The window's subject and centre item, for the hand-over test.
@Observable
@MainActor
private final class PulledUpWindowProbe {
    var subject: WindowSubject
    var centreItem: CentreItem?
    init(subject: WindowSubject) { self.subject = subject }
}

/// The centre's cover beside the pulled-up view, as the window lays them out.
@MainActor
private struct PulledUpBesideTheCentre: View {
    let f: StatementMountFixture
    @Bindable var probe: PulledUpWindowProbe

    var body: some View {
        HStack(spacing: 0) {
            ZStack {
                Color.clear
                if let item = probe.centreItem {
                    CentreItemCover(store: f.store, documentStore: f.documentStore, item: item,
                                    bible: nil, world: nil, window: nil, findIsUp: false,
                                    onClose: { probe.centreItem = nil })
                }
            }
            .frame(width: 400)
            PulledUpView(
                store: f.store, documentStore: f.documentStore,
                subject: $probe.subject, centreItem: probe.centreItem,
                canvasModel: CanvasModel(), editorControl: EditorControl(),
                figureListing: FigureListingModel(), figureGridPresence: FigureGridPresence(),
                figureWindows: nil, window: nil, isLocked: false, figureTree: nil,
                bible: nil, world: nil, onOpenInCentre: { _ in })
                .frame(width: 340)
        }
    }
}

// MARK: - Hand-overs between two editors of one item (fix 2)

/// Which of two places shows an item's editor: the centre side (the palette
/// wall, the centre's research route) or the pulled-up side.
@Observable
@MainActor
private final class HandOverProbe {
    var inTheCentre = true
    init() {}
}

/// Two editors of one item, exactly one mounted at a time, side by side —
/// what the window does when the wall takes or releases a card the pulled-up
/// view also names, or a note moves between beside and the centre.
@MainActor
private struct HandOverHost: View {
    let store: ProjectStore
    let documentStore: DocumentStore
    let itemId: String
    /// nil: a palette card; else the note's path.
    let notePath: String?
    let probe: HandOverProbe

    var body: some View {
        HStack(spacing: 0) {
            Group {
                if probe.inTheCentre { editor(second: false) } else { Color.clear }
            }
            .frame(width: 420)
            Group {
                if !probe.inTheCentre { editor(second: true) } else { Color.clear }
            }
            .frame(width: 360)
        }
    }

    @ViewBuilder
    private func editor(second: Bool) -> some View {
        if let notePath {
            ResearchNoteEditor(store: store, documentStore: documentStore, path: notePath,
                               itemId: itemId, previewVisible: false, lockEditing: false,
                               isSecondEditor: second)
        } else {
            PaletteCardEditor(store: store, cardId: itemId)
        }
    }
}

/// **The taking editor seeds with the releasing editor's unsaved edit** —
/// both directions, for a palette card (the wall and the pulled-up view) and
/// a research note (the centre and the pulled-up view). The edit is typed
/// into the real editor's text view and is still pending in the note door
/// when the other editor mounts. Nothing presses a control (tripwire 33).
@MainActor
final class EditorHandOverTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        FontWarmup.ensure()
    }

    private var root: URL!
    private var store: ProjectStore!
    private var documentStore: DocumentStore!
    private var preferences: UserPreferences!
    private var suite = ""
    private var windows: [NSWindow] = []

    override func setUp() async throws {
        root = TestTemp.root.appendingPathComponent("hand-over-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = try await ProjectFactory.createNovelProject(named: "HandOver", in: root)
        store = try await ProjectStore.load(from: url)
        await store.wordCountPopulationTask?.value
        documentStore = try await DocumentStore.open(url: url)
        store.documentStore = documentStore
        documentStore.projectStore = store
        suite = "hand-over-\(UUID().uuidString)"
        preferences = UserPreferences(defaults: UserDefaults(suiteName: suite)!)
    }

    override func tearDown() async throws {
        for window in windows { window.contentView = NSView(frame: .zero) }
        pump(0.05)
        windows = []
        await documentStore?.close()
        UserDefaults.standard.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }

    func test_aPaletteCardHandedBetweenTheWallAndThePulledUpViewKeepsTheUnsavedEdit() async throws {
        let item = try await store.addPaletteCard(title: "Harbour", kind: .location)
        try await handOver(itemId: item.id, notePath: nil,
                           typed: ["Gulls.", " Tar."])
    }

    func test_aNoteHandedBetweenTheCentreAndThePulledUpViewKeepsTheUnsavedEdit() async throws {
        let note = try await store.addResearchTextNote(parentId: nil, title: "Tides")
        let path = try XCTUnwrap(store.findResearchItem(id: note.id, in: store.manifest.research)?.path)
        try await handOver(itemId: note.id, notePath: path,
                           typed: ["Neap.", " Spring."])
    }

    /// Mount the centre side, type, flip to the pulled-up side inside the
    /// debounce; type there, flip back. Each taking editor shows every word.
    private func handOver(itemId: String, notePath: String?, typed: [String]) async throws {
        let probe = HandOverProbe()
        let window = TestWindow.mount(
            AnyView(HandOverHost(store: store, documentStore: documentStore, itemId: itemId,
                                 notePath: notePath, probe: probe).environment(preferences)),
            size: CGSize(width: 800, height: 700))
        windows.append(window)
        await pumpUntil(deadline: 5) { self.textView(in: window, centre: true) != nil }
        await waitOut(0.2)
        var expected = try XCTUnwrap(textView(in: window, centre: true),
                                     "premise: the centre side's editor").string
        for (index, words) in typed.enumerated() {
            let side = probe.inTheCentre
            await pumpUntil(deadline: 5) { self.textView(in: window, centre: side)?.string == expected }
            let editor = try XCTUnwrap(textView(in: window, centre: side), "the editor seeded")
            XCTAssertEqual(editor.string, expected,
                           "hand-over \(index): the taking editor seeds with every word so far")
            type(words, into: editor)
            expected += words
            XCTAssertTrue(documentStore.researchNoteHasPendingSave(itemId: itemId),
                          "premise: the edit is still waiting in the note door")
            probe.inTheCentre.toggle()
        }
        let side = probe.inTheCentre
        await pumpUntil(deadline: 5) { self.textView(in: window, centre: side)?.string == expected }
        XCTAssertEqual(textView(in: window, centre: side)?.string, expected,
                       "the last taking editor seeds with the releasing editor's unsaved edit")
    }

    private func type(_ text: String, into textView: NSTextView) {
        textView.window?.makeFirstResponder(textView)
        textView.setSelectedRange(NSRange(location: (textView.string as NSString).length, length: 0))
        for character in text {
            let s = String(character)
            let range = textView.selectedRange()
            guard textView.shouldChangeText(in: range, replacementString: s) else { continue }
            textView.textStorage?.replaceCharacters(in: range, with: s)
            textView.setSelectedRange(NSRange(location: range.location + (s as NSString).length, length: 0))
            textView.didChangeText()
        }
        pump(0.1)
    }

    /// The editable body text view on one side (the card's Notes, or the
    /// note) — by where it is drawn, so a view on its way out is never read.
    private func textView(in window: NSWindow, centre: Bool) -> NSTextView? {
        guard let root = window.contentView else { return nil }
        var found: [NSTextView] = []
        func collect(_ view: NSView) {
            if let hit = view as? NSTextView, hit.isEditable, !hit.isFieldEditor, hit.window != nil {
                let midX = (hit.enclosingScrollView ?? hit).convert(
                    (hit.enclosingScrollView ?? hit).bounds, to: nil).midX
                if (midX < 420) == centre { found.append(hit) }
            }
            view.subviews.forEach(collect)
        }
        collect(root)
        return found.first
    }
}
