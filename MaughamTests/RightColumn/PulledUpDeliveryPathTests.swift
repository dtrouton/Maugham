import XCTest
import AppKit
import SwiftUI
import Observation
import MaughamCore
@testable import Maugham

/// **The whole-branch review's findings on the pulled-up thing**, each on
/// the path production takes (the review's lesson: a probe built with other
/// arguments than its one host passes hid a dead feature, C1):
/// - C1: the centre's details above what is pulled up, mounted with the
///   canvas's details the way `RightColumn` passes them;
/// - I1: an explicit pull-up over a standing canvas selection shows the
///   pulled-up thing, and the next selection covers it again;
/// - I2: ⌘⌥N's focus request claims on its edge and lets go when it gives up;
/// - M1–M3, M7, M8 and the region row's count.
///
/// Mounted tests are measurements only (tripwire 33): the subject and the
/// canvas's selection are written as their production writers write them,
/// never by pressing a mounted control.
@MainActor
final class PulledUpDeliveryPathTests: XCTestCase {

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

    /// Every label and value the window publishes (a section's header is a
    /// button whose value is "collapsed" and whose label is its line).
    private func texts(_ f: StatementMountFixture, _ window: NSWindow) -> [String] {
        (try? axTexts(in: window)) ?? []
    }

    // MARK: - C1: the centre's details, with the host's canvas details

    /// A figure in the centre and a note pulled up, the view built as
    /// `RightColumn` builds it (`canvasDetails` passed): "Details of <the
    /// figure>" stands above the note. Before the fix the canvas's cover
    /// branch took every pulled-up thing, so the line never drew.
    func test_theCentresDetailsStandAboveAPulledUpNoteAsTheColumnBuildsIt() async throws {
        let f = try await fixture("CentreDetailsPath")
        try requireAssistiveClient()
        let figure = try await f.store.createFigure(kind: .table, name: "Rainfall", piece: nil)
        let note = try await f.store.addResearchTextNote(parentId: nil, title: "Tides")
        let probe = CoverProbe(WindowSubject(open: .figure(figure.id), faces: .figure(figure.id),
                                             beside: .research(note.id)))
        let window = f.hostView(AnyView(CoverHost(f: f, probe: probe, model: CanvasModel(),
                                                  memory: PulledUpMemory())), width: 360)
        let line = CentreDetailsSection<EmptyView>.line("Rainfall")
        await pumpUntil(deadline: 5) { self.texts(f, window).contains(line) }
        XCTAssertTrue(texts(f, window).contains(line),
                      "the centre's details stand above the pulled-up note: \(texts(f, window))")
        XCTAssertFalse(texts(f, window).contains(CoverHost.canvasDetailsMarker),
                       "the canvas's details are not drawn with a figure in the centre")
    }

    /// The mirror: the canvas in the centre, something pulled up, and the
    /// writer selecting a card on it: the canvas's details cover the
    /// pulled-up thing, and no "Details of" line draws.
    func test_onTheCanvasASelectionMadeAfterThePullUpCoversIt() async throws {
        let f = try await fixture("CanvasCoverPath")
        try requireAssistiveClient()
        let note = try await f.store.addResearchTextNote(parentId: nil, title: "Tides")
        let model = CanvasModel()
        let probe = CoverProbe(WindowSubject(open: .canvas, faces: .canvas, beside: .research(note.id)))
        let window = f.hostView(AnyView(CoverHost(f: f, probe: probe, model: model,
                                                  memory: PulledUpMemory())), width: 360)
        let covered = CanvasDetailsCover<EmptyView>.coveredLine("Tides")
        await pumpUntil(deadline: 5) { self.texts(f, window).contains("Tides") }
        model.selection = .node(CanvasNodeID("n-1"))
        await pumpUntil(deadline: 5) { self.texts(f, window).contains(covered) }
        XCTAssertTrue(texts(f, window).contains(covered), "covered: \(texts(f, window))")
        XCTAssertTrue(texts(f, window).contains(CoverHost.canvasDetailsMarker))
        XCTAssertFalse(texts(f, window).contains { $0.hasPrefix("Details of") })
    }

    // MARK: - I1: an explicit pull-up over a standing selection

    /// The canvas in the centre with a card selected, then a note pulled up
    /// (the click rule's act, as a fold row, a key or Back makes it): the
    /// note shows, and the writer's canvas selection stands. Selecting again
    /// covers it; pulling up another thing shows that one.
    func test_anExplicitPullUpOverAStandingCanvasSelectionShowsThePulledUpThing() async throws {
        let f = try await fixture("PullUpOverSelection")
        try requireAssistiveClient()
        let tides = try await f.store.addResearchTextNote(parentId: nil, title: "Tides")
        let shoals = try await f.store.addResearchTextNote(parentId: nil, title: "Shoals")
        let model = CanvasModel()
        let memory = PulledUpMemory()
        let probe = CoverProbe(WindowSubject(open: .canvas, faces: .canvas))
        let window = f.hostView(AnyView(CoverHost(f: f, probe: probe, model: model,
                                                  memory: memory)), width: 360)
        // The writer's selection, its own event before the pull-up.
        model.selection = .node(CanvasNodeID("n-1"))
        await pumpUntil(deadline: 5) { memory.canvasSelectionIsNewer }
        XCTAssertTrue(memory.canvasSelectionIsNewer, "premise: the window's watch saw the selection")
        XCTAssertTrue(texts(f, window).contains(CoverHost.canvasDetailsMarker),
                      "premise: nothing pulled up, the canvas's details fill the position")

        probe.subject = ClickRule.pullUp(.research(tides.id), current: probe.subject)
        await pumpUntil(deadline: 5) { self.texts(f, window).contains("Tides") }
        await waitOut(0.2)
        XCTAssertTrue(texts(f, window).contains("Tides"), "the note the writer asked for shows")
        XCTAssertFalse(texts(f, window).contains(CanvasDetailsCover<EmptyView>.coveredLine("Tides")),
                       "not under the cover: \(texts(f, window))")
        XCTAssertEqual(model.selection, .node(CanvasNodeID("n-1")), "the canvas selection is kept")

        model.selection = .node(CanvasNodeID("n-2"))
        let covered = CanvasDetailsCover<EmptyView>.coveredLine("Tides")
        await pumpUntil(deadline: 5) { self.texts(f, window).contains(covered) }
        XCTAssertTrue(texts(f, window).contains(covered), "a newer selection covers it again")

        probe.subject = ClickRule.pullUp(.research(shoals.id), current: probe.subject)
        await pumpUntil(deadline: 5) { self.texts(f, window).contains("Shoals") }
        await waitOut(0.2)
        XCTAssertFalse(texts(f, window).contains(CanvasDetailsCover<EmptyView>.coveredLine("Shoals")),
                       "another pull-up shows: \(texts(f, window))")
        XCTAssertEqual(model.selection, .node(CanvasNodeID("n-2")))
    }

    /// **The rule, as a table**: the cover needs the canvas in the centre,
    /// something pulled up, a selection, and that selection newer than the
    /// last pull-up.
    func test_theCanvasCoverRuleAsATable() {
        for centre in [true, false] {
            for pulled in [true, false] {
                for selection in [true, false] {
                    for newer in [true, false] {
                        XCTAssertEqual(
                            RightColumnContent.canvasDetailsCover(
                                canvasIsTheCentre: centre, somethingIsPulledUp: pulled,
                                canvasHasASelection: selection, selectionIsNewerThanPullUp: newer),
                            centre && pulled && selection && newer,
                            "\(centre) \(pulled) \(selection) \(newer)")
                    }
                }
            }
        }
    }

    /// The memory's two writers: a selection change arms the cover; a
    /// change of what is pulled up, or a pull-up of what is already up (a
    /// key, Back, a Brief link: `ProjectWindow.pullUp`), disarms it.
    func test_aPullUpDisarmsTheCoverAndASelectionChangeArmsIt() {
        let memory = PulledUpMemory()
        XCTAssertFalse(memory.canvasSelectionIsNewer, "a window opens with nothing newer")
        memory.canvasSelectionChanged()
        XCTAssertTrue(memory.canvasSelectionIsNewer)
        memory.record(from: nil, to: .lessons)
        XCTAssertFalse(memory.canvasSelectionIsNewer, "a change of what is pulled up")
        memory.canvasSelectionChanged()
        var subject = WindowSubject(open: .canvas, faces: .canvas, beside: .lessons)
        var shows = true
        var position = RightColumnPosition.pulledUp
        ProjectWindow.pullUp(.lessons,
                             subject: Binding(get: { subject }, set: { subject = $0 }),
                             showInspector: Binding(get: { shows }, set: { shows = $0 }),
                             position: Binding(get: { position }, set: { position = $0 }),
                             memory: memory)
        XCTAssertFalse(memory.canvasSelectionIsNewer,
                       "pulling up what is already up shows it too: the subject did not change")
    }

    // MARK: - I2: ⌘⌥N's focus request

    /// A standing request claims once, on its false→true edge — a re-render
    /// with the request still up does not start another claim — and the
    /// probe tells its host when it gives up, so the request is let go and
    /// never steals the keys later.
    func test_aFocusRequestClaimsOnItsEdgeAndLetsGoWhenItGivesUp() async throws {
        let probe = EditorFocusProbe.ProbeView()
        probe.stepsAllowed = 0
        var gaveUp = 0
        probe.onGaveUp = { gaveUp += 1 }
        probe.update(wanted: true)
        XCTAssertEqual(probe.generation, 1, "the request claims")
        probe.update(wanted: true)
        XCTAssertEqual(probe.generation, 1, "a re-render with the request standing claims nothing new")
        await pumpUntil(deadline: 2) { gaveUp == 1 }
        XCTAssertEqual(gaveUp, 1, "no editor: the probe gives up and says so")
        probe.update(wanted: false)
        probe.update(wanted: true)
        XCTAssertEqual(probe.generation, 2, "a new request claims again")

        let goingFor = try SourceTree.read("Maugham/Views/Brief/GoingForView.swift")
            .components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
        XCTAssertTrue(goingFor.contains("EditorFocusProbe(wanted: wantsKeys, onFocused: { wantsKeys = false }, "
                                        + "onGaveUp: { wantsKeys = false })"),
                      "Going for lets its request go when the probe gives up")
    }

    // MARK: - M3: Back is offered exactly when a press brings something

    /// A history holding only a card no longer on the canvas offers no Back
    /// (the press would bring nothing); a note that resolves offers it, and
    /// the press brings that note.
    func test_backIsOfferedExactlyWhenAPressBringsSomething() async throws {
        let f = try await fixture("BackOffered")
        let note = try await f.store.addResearchTextNote(parentId: nil, title: "Tides")
        let memory = PulledUpMemory()
        memory.history = PulledUpHistory(entries: [.canvasScrap(nodeId: "gone")])
        memory.refreshBack(from: nil, store: f.store)
        XCTAssertNil(memory.backTarget, "a gone card offers no Back")
        XCTAssertNil(memory.takeBack(from: nil, store: f.store), "and the press brings nothing")

        memory.history = PulledUpHistory(entries: [.research(note.id), .canvasScrap(nodeId: "gone")])
        memory.refreshBack(from: nil, store: f.store)
        XCTAssertEqual(memory.backTarget, .research(note.id))
        XCTAssertEqual(memory.takeBack(from: nil, store: f.store), .research(note.id),
                       "the press brings what was offered")
    }

    // MARK: - M1: this window's canvas

    /// The fold's Open in Centre and the control's region title read THIS
    /// window's canvas, never the newest window's (`store.liveCanvas`).
    func test_theFoldAndTheControlUseThisWindowsCanvas() throws {
        for file in ["Maugham/Views/BinderPieceFold.swift", "Maugham/Views/RightColumnControl.swift"] {
            let code = SourceScan.codeLines(of: try SourceTree.read(file)).joined(separator: "\n")
            XCTAssertFalse(code.contains("store.liveCanvas"), "\(file) reads the newest window's canvas")
        }
        let fold = SourceScan.codeLines(of: try SourceTree.read("Maugham/Views/BinderPieceFold.swift"))
            .joined(separator: "\n")
        XCTAssertTrue(fold.contains("windowCanvas?.revealAndSelect(target)"))
        let window = try SourceTree.read("Maugham/Views/ProjectWindow.swift")
        XCTAssertTrue(window.contains(".environment(\\.windowCanvas, canvasModel)"))
        XCTAssertFalse("x.store.liveCanvas?.y".range(of: "store.liveCanvas") == nil, "the planted control")
    }

    // MARK: - M2: a promoted region, one reading

    /// A region promoted to a note: the fold's region row (through the shelf
    /// the fold reads, `PinnedReferenceResolver.shelves`) holds what the
    /// region pulled up holds — the note, then its cards in the canvas's
    /// visual order. The study's shelf keeps the note alone (§2.3).
    func test_aPromotedRegionsFoldRowHoldsWhatThePulledUpRegionShows() throws {
        var s = CanvasScene()
        let region = CanvasRegionID("rg-1")
        var r = CanvasRegion(id: region, label: "Fog", frame: CGRect(x: 0, y: 0, width: 600, height: 900))
        r.boundPieceID = "ch-1"
        r.promotedItemID = "res-summary"
        s.insertRegion(r)
        let low = CanvasNodeID("a-scrap"), note = CanvasNodeID("b-note"), picture = CanvasNodeID("c-picture")
        s.insert(CanvasNode(id: low, kind: .scrap, origin: CGPoint(x: 0, y: 600), width: 240, cachedHeight: 80))
        s.insert(CanvasNode(id: note, kind: .item(.project(id: "res-note")),
                            origin: CGPoint(x: 0, y: 0), width: 240, cachedHeight: 80))
        s.insert(CanvasNode(id: picture, kind: .item(.owned(path: "canvas_assets/p.png")),
                            origin: CGPoint(x: 0, y: 300), width: 240, cachedHeight: 80))
        for id in [low, note, picture] { CanvasMembership.join(id, home: region, in: &s) }
        let items = CanvasItemIndex.over(research: [
            ResearchItem(id: "res-note", title: "The falls", type: .asset, kind: .document,
                         path: "research/falls.md"),
            ResearchItem(id: "res-summary", title: "Fog, summed", type: .asset, kind: .document,
                         path: "research/fog.md"),
        ])
        let scraps = [low: "Low words"]

        guard case .region(_, let members) = PulledUpRegionView.read(region.raw, scene: s, scraps: scraps,
                                                                     items: items) else {
            return XCTFail("premise: the region reads")
        }
        let fold = PinnedReferences.pinned(forDocId: "ch-1", links: [], derived: [], scene: s,
                                           scraps: scraps, items: items,
                                           promotedRegionsListTheirCards: true)
        let section = try XCTUnwrap(fold.sections.first { $0.regionId == region })
        let asMembers = section.references.map { ref -> String in
            switch ref.kind {
            case .scrap(let nodeId): return "scrap:\(nodeId)"
            case .photo(let path): return "picture:\(path)"
            case .research(let id), .palette(let id): return "item:\(id)"
            }
        }
        XCTAssertEqual(asMembers, members.map(\.id), "the fold's region row and the region beside agree")
        XCTAssertEqual(asMembers.first, "item:res-summary", "the note the region became, first")

        let study = PinnedReferences.pinned(forDocId: "ch-1", links: [], derived: [], scene: s,
                                            scraps: scraps, items: items)
        XCTAssertEqual(study.sections.first { $0.regionId == region }?.references.map(\.id),
                       ["res-summary"], "the study's shelf keeps §2.3: the note alone")
        let foldIndex = try SourceTree.read("Maugham/Views/PieceFoldContents.swift")
        XCTAssertTrue(foldIndex.contains("promotedRegionsListTheirCards: true"),
                      "the fold's shelves read the region's cards")
        let resolver = try SourceTree.read("Maugham/Compiler/PinnedReferenceResolver.swift")
        XCTAssertTrue(resolver.contains("promotedRegionsListTheirCards: false)[docId]"),
                      "the briefing's shelf keeps the note alone")
    }

    // MARK: - Writer's seat 4: the region row's count says what it counts

    func test_aRegionRowsCountSaysWhatItCounts() throws {
        XCTAssertEqual(BinderPieceFold.regionCount(3), "3 cards")
        XCTAssertEqual(BinderPieceFold.regionCount(1), "1 card")
        let fold = try SourceTree.read("Maugham/Views/BinderPieceFold.swift")
        XCTAssertFalse(fold.contains(".foregroundStyle(.tertiary)"), "the count reads in secondary ink")
    }

    // MARK: - M7: thumbnails in every tree host

    /// Every host of the tree's Research rows resolves their pictures, the
    /// screenplay's Scenes navigator among them.
    func test_everyTreeHostResolvesRowThumbnails() throws {
        for file in ["Maugham/Views/BinderView.swift", "Maugham/Views/CollectionPiecesPane.swift",
                     "Maugham/Views/SceneNavigatorPane.swift"] {
            XCTAssertTrue(try SourceTree.read(file).contains(".environment(\\.rowThumbnailRoot, store.url)"),
                          "\(file) draws no thumbnails")
        }
    }

    // MARK: - M8: a region's pictures decode off the main actor

    func test_aPulledUpRegionsPicturesDecodeOffTheMainActorAtColumnSize() throws {
        let code = SourceScan.codeLines(of: try SourceTree.read("Maugham/Views/PulledUpRegionView.swift"))
            .joined(separator: "\n")
        XCTAssertTrue(code.contains("CanvasThumbnails.decode("), "the canvas's one decoder, capped")
        XCTAssertTrue(code.contains("Task.detached"), "off the main actor")
        XCTAssertFalse(code.contains("NSImage(contentsOf:"), "no full-size decode on the main actor")
    }
}

/// The window's subject, held outside the views.
@Observable
@MainActor
private final class CoverProbe {
    var subject: WindowSubject
    init(_ subject: WindowSubject) { self.subject = subject }
}

/// `PulledUpView` as `RightColumn` builds it — the canvas's details passed —
/// under the window's pulled-up wiring, as `ProjectWindow` mounts it.
@MainActor
private struct CoverHost: View {
    let f: StatementMountFixture
    @Bindable var probe: CoverProbe
    let model: CanvasModel
    let memory: PulledUpMemory

    static let canvasDetailsMarker = "The canvas's details, drawn by the host"

    var body: some View {
        PulledUpView(
            store: f.store, documentStore: f.documentStore, subject: $probe.subject,
            centreItem: nil, canvasModel: model,
            editorControl: EditorControl(), figureListing: FigureListingModel(),
            figureGridPresence: FigureGridPresence(), figureWindows: nil,
            window: nil, isLocked: false, figureTree: nil,
            bible: nil, world: nil,
            onOpenInCentre: { _ in },
            memory: memory,
            canvasDetails: { AnyView(Text(Self.canvasDetailsMarker)) })
            .modifier(PulledUpHistoryWiring(
                store: f.store, window: nil, subject: $probe.subject, memory: memory,
                showInspector: .constant(true), position: .constant(.pulledUp),
                canvasModel: model))
    }
}
