import XCTest
import MaughamCore
@testable import Maugham

final class RegionBindingTests: XCTestCase {

    private var root: URL!
    private let r1 = CanvasRegionID("r1")
    private let r2 = CanvasRegionID("r2")
    private let a = CanvasNodeID("a")
    private let b = CanvasNodeID("b")
    private let c = CanvasNodeID("c")

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("region-binding-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func scene() -> CanvasScene {
        var s = CanvasScene()
        for id in [a, b, c] {
            s.insert(CanvasNode(id: id, kind: .scrap, origin: .zero,
                                width: 240, cachedHeight: 80))
        }
        for (id, label) in [(r1, "Act II fog"), (r2, "Falls")] {
            s.insertRegion(CanvasRegion(id: id, label: label,
                                        frame: CGRect(x: 0, y: 0, width: 600, height: 400)))
        }
        return s
    }

    private func model() -> CanvasModel {
        let m = CanvasModel()
        m.attach(projectRoot: root)
        m.withScene { $0 = self.scene() }
        m.selection = .region(r1)
        return m
    }

    private func inspector(_ m: CanvasModel) -> RegionInspector {
        RegionInspector(model: m, regionID: r1,
                        pieces: [RegionInspector.PieceChoice(id: "piece-3", title: "October")])
    }

    // MARK: - The binding rules

    func test_onlyResidentsAreBoundToThePiece() {
        var s = scene()
        CanvasMembership.join(a, home: r1, in: &s)
        CanvasMembership.addAppearance(b, to: r1, in: &s)
        RegionBinding.bind(r1, toPiece: "piece-3", in: &s)
        XCTAssertEqual(RegionBinding.references(forPiece: "piece-3", in: s), [a],
                       "§4.4: a visitor is not bound, or two regions sharing a "
                       + "card would each claim it")
    }

    func test_twoRegionsBoundToOnePieceUnionTheirResidents() {
        var s = scene()
        CanvasMembership.join(a, home: r1, in: &s)
        CanvasMembership.join(b, home: r2, in: &s)
        RegionBinding.bind(r1, toPiece: "piece-3", in: &s)
        RegionBinding.bind(r2, toPiece: "piece-3", in: &s)
        XCTAssertEqual(RegionBinding.references(forPiece: "piece-3", in: s), [a, b])
    }

    func test_unbindingKeepsMembershipIntact() throws {
        var s = scene()
        CanvasMembership.join(a, home: r1, in: &s)
        RegionBinding.bind(r1, toPiece: "piece-3", in: &s)
        RegionBinding.unbind(r1, in: &s)
        XCTAssertNil(RegionBinding.boundPiece(of: r1, in: s))
        XCTAssertTrue(try XCTUnwrap(s.region(r1)).livesHere(a), "the binding is not the membership")
        XCTAssertTrue(RegionBinding.references(forPiece: "piece-3", in: s).isEmpty)
    }

    /// The brief's version ran against a scene with no members at all, so
    /// dropping the `boundPieceID == piece` filter entirely left it green —
    /// every region matched and every region contributed nothing. A resident and
    /// a real binding to a DIFFERENT piece are what make the filter observable.
    func test_aPieceNobodyBoundToHasNoReferences() {
        var s = scene()
        CanvasMembership.join(a, home: r1, in: &s)
        RegionBinding.bind(r1, toPiece: "piece-3", in: &s)
        XCTAssertTrue(RegionBinding.references(forPiece: "piece-9", in: s).isEmpty)
        XCTAssertEqual(RegionBinding.references(forPiece: "piece-3", in: s), [a],
                       "the control: the filter lets the right piece through")
    }

    /// `remove` scrubs the region records, but a hand-edited sidecar is not
    /// obliged to be coherent — and a stale id here becomes a pinned reference
    /// to a card that is not on the canvas.
    func test_aResidentThatIsNoLongerACardIsNotAReference() throws {
        var s = scene()
        CanvasMembership.join(a, home: r1, in: &s)
        CanvasMembership.join(b, home: r1, in: &s)
        RegionBinding.bind(r1, toPiece: "piece-3", in: &s)
        // Reach past `CanvasScene.remove`, which would scrub the membership too.
        var starved = CanvasScene(nodes: [CanvasNode(id: b, kind: .scrap, origin: .zero,
                                                     width: 240, cachedHeight: 80)],
                                  regions: s.regions)
        starved.insertRegion(try XCTUnwrap(s.region(r1)))
        XCTAssertEqual(RegionBinding.references(forPiece: "piece-3", in: starved), [b])
    }

    // MARK: - The inspector, which is the only way any of this is reachable

    func test_renamingThroughTheInspectorIsOneUndoStepAndReachesDisk() {
        let m = model()
        inspector(m).commitLabel("Falls at night")
        m.flush()
        XCTAssertEqual(CanvasStore(projectRoot: root).load().scene.region(r1)?.label,
                       "Falls at night")
        m.undo.undo()
        XCTAssertEqual(m.scene.region(r1)?.label, "Act II fog")
        XCTAssertFalse(m.undo.canUndo, "one rename, one step — not one per keystroke")
    }

    /// The writer-facing rule. **It does not pin the guard** — `endGesture`
    /// already declines an unchanged gesture, so this stays green with
    /// `commitLabel`'s `region.label != new` deleted. The test below is the one
    /// that pins it; this one says what the writer is owed.
    func test_committingTheSameLabelTwiceLeavesOneStep() {
        let m = model()
        inspector(m).commitLabel("Falls")
        inspector(m).commitLabel("Falls")
        m.undo.undo()
        XCTAssertEqual(m.scene.region(r1)?.label, "Act II fog",
                       "a commit on focus loss that changed nothing must not push "
                       + "a step the writer has to press ⌘Z twice to get past")
    }

    /// A rename typed into r1's field and committed after the selection has
    /// already moved to r2 must land on r1. The inspector commits on focus loss
    /// and on the selection moving on, and it does not control which of those
    /// two AppKit and SwiftUI deliver first.
    func test_aRenameCommitsToTheRegionItWasTypedIn() {
        let m = model()
        let showingTheOtherRegion = RegionInspector(model: m, regionID: r2, pieces: [])
        showingTheOtherRegion.commitLabel("Falls at night", to: r1)
        XCTAssertEqual(m.scene.region(r1)?.label, "Falls at night")
        XCTAssertEqual(m.scene.region(r2)?.label, "Falls",
                       "and not on whichever region is on screen by then")
    }

    /// Both directions of the change-check, which is the trap the brief names:
    /// a guard that is easy to test only in the direction that passes.
    ///
    /// The observable is the structural counter, because that is what the guard
    /// actually protects — a canvas redraw and a queued disk write for an edit
    /// that changed nothing.
    func test_theChangeCheckSwallowsNoOpsAndOnlyNoOps() {
        let m = model()
        let i = inspector(m)

        let before = m.sceneRevision
        i.commitLabel("Act II fog")
        i.commitCollapsed(false)
        i.commitBinding(nil)
        i.remove(a)
        XCTAssertEqual(m.sceneRevision, before,
                       "four commits, none of which changed anything — remove the "
                       + "`!=` guards and every one of them redraws the canvas")

        i.commitLabel("Falls at night")
        XCTAssertEqual(m.sceneRevision, before + 1)
        i.commitCollapsed(true)
        XCTAssertEqual(m.sceneRevision, before + 2)
        i.commitBinding("piece-3")
        XCTAssertEqual(m.sceneRevision, before + 3,
                       "and a guard that swallows a REAL change is the same defect "
                       + "wearing the opposite sign")
    }

    func test_collapsingThroughTheInspectorHidesTheResidents() {
        let m = model()
        m.withScene { CanvasMembership.join(self.a, home: self.r1, in: &$0) }
        inspector(m).commitCollapsed(true)
        XCTAssertTrue(m.scene.isHidden(a))
        inspector(m).commitCollapsed(false)
        XCTAssertFalse(m.scene.isHidden(a))
    }

    func test_collapsingIsOneUndoStepAndReachesDisk() {
        let m = model()
        inspector(m).commitCollapsed(true)
        m.flush()
        XCTAssertEqual(CanvasStore(projectRoot: root).load().scene.region(r1)?.isCollapsed,
                       true, "the field Task 2 round-trips and only a test could set")
        m.undo.undo()
        XCTAssertEqual(m.scene.region(r1)?.isCollapsed, false)
    }

    func test_bindingThroughTheInspectorReachesDisk() {
        let m = model()
        inspector(m).commitBinding("piece-3")
        m.flush()
        XCTAssertEqual(CanvasStore(projectRoot: root).load().scene.region(r1)?.boundPieceID,
                       "piece-3")
    }

    func test_unbindingThroughTheInspectorClearsIt() {
        let m = model()
        inspector(m).commitBinding("piece-3")
        inspector(m).commitBinding(nil)
        XCTAssertNil(m.scene.region(r1)?.boundPieceID)
        m.undo.undo()
        XCTAssertEqual(m.scene.region(r1)?.boundPieceID, "piece-3",
                       "the unbind is its own step, not a silent write")
    }

    func test_removingAMemberThroughTheInspectorIsAnExplicitAct() throws {
        let m = model()
        m.withScene { CanvasMembership.join(self.a, home: self.r1, in: &$0) }
        inspector(m).remove(a)
        XCTAssertFalse(try XCTUnwrap(m.scene.region(r1)).livesHere(a))
        XCTAssertNotNil(m.scene.node(a), "removing from a region never deletes the card")
        m.undo.undo()
        XCTAssertTrue(try XCTUnwrap(m.scene.region(r1)).livesHere(a))
    }

    func test_removingAVisitorLeavesTheRegionItLivesIn() throws {
        let m = model()
        m.withScene {
            CanvasMembership.join(self.a, home: self.r2, in: &$0)
            CanvasMembership.addAppearance(self.a, to: self.r1, in: &$0)
        }
        inspector(m).remove(a)
        XCTAssertFalse(try XCTUnwrap(m.scene.region(r1)).appearsHere(a))
        XCTAssertTrue(try XCTUnwrap(m.scene.region(r2)).livesHere(a),
                      "the inspector removes from THIS region, not from every region")
    }

    func test_theInspectorListsResidentsAndVisitorsSeparately() {
        let m = model()
        m.withScene {
            CanvasMembership.join(self.a, home: self.r1, in: &$0)
            CanvasMembership.addAppearance(self.b, to: self.r1, in: &$0)
        }
        let i = inspector(m)
        XCTAssertEqual(i.residents.map(\.node), [a])
        XCTAssertEqual(i.visitors.map(\.node), [b],
                       "§4.3: any region should answer 'which of these live here "
                       + "and which are visiting' at a glance")
    }

    /// Three residents whose titles sort the opposite way from their ids, so a
    /// list that fell back on the id — or on `Set` iteration order — is a
    /// different list.
    func test_theMemberListIsOrderedByTheTitleTheCanvasShows() {
        let m = model()
        m.withScene {
            for id in [self.a, self.b, self.c] {
                CanvasMembership.join(id, home: self.r1, in: &$0)
            }
        }
        m.setScrapText("Zermatt", for: a)
        m.setScrapText("Aare", for: b)
        m.setScrapText("Matterhorn", for: c)
        XCTAssertEqual(inspector(m).residents.map(\.title),
                       ["Aare", "Matterhorn", "Zermatt"])
        XCTAssertEqual(inspector(m).residents.map(\.node), [b, c, a],
                       "title order, which here is not the id order")
    }

    /// The id tiebreak. Every empty card answers `chipTitle` with the same
    /// placeholder, so title alone leaves a `Set`'s iteration order deciding the
    /// list, through a `sorted(by:)` that is not documented as stable — a
    /// different order on every launch, in the common case of a region full of
    /// cards the writer has just made and not yet typed into.
    ///
    /// **EIGHT cards, and the count is the assertion.** With two or three, a
    /// title-only comparator lands on the id order by chance often enough that
    /// the mutation stays green — measured. At eight there are 40,320 orders and
    /// only one of them passes.
    func test_cardsSharingATitleAreOrderedByIdRatherThanByChance() {
        let m = model()
        let empties = (1...8).map { CanvasNodeID("n\($0)") }
        m.withScene { scene in
            for id in empties {
                scene.insert(CanvasNode(id: id, kind: .scrap, origin: .zero,
                                        width: 240, cachedHeight: 80))
                CanvasMembership.join(id, home: self.r1, in: &scene)
            }
        }
        for id in empties { m.setScrapText("", for: id) }

        let rows = inspector(m).residents
        XCTAssertEqual(Set(rows.map(\.title)), [CanvasAccessibility.emptyScrapValue],
                       "the control: every one of them has the same title")
        XCTAssertEqual(rows.map(\.node.raw), empties.map(\.raw).sorted())
    }

    func test_aMemberThatIsNoLongerACardIsNotListed() {
        let m = model()
        m.withScene {
            CanvasMembership.join(self.a, home: self.r1, in: &$0)
            CanvasMembership.addAppearance(self.b, to: self.r1, in: &$0)
        }
        // Reach past `CanvasScene.remove`, which scrubs the region records too.
        m.withScene { scene in
            var rebuilt = CanvasScene(nodes: [], regions: scene.regions)
            rebuilt.insert(CanvasNode(id: self.c, kind: .scrap, origin: .zero,
                                      width: 240, cachedHeight: 80))
            scene = rebuilt
        }
        let i = inspector(m)
        XCTAssertTrue(i.residents.isEmpty, "a stale resident id is not a row")
        XCTAssertTrue(i.visitors.isEmpty, "and neither is a stale visitor id")
    }

    func test_deletingTheRegionFromTheInspectorLeavesTheCards() {
        let m = model()
        m.withScene { CanvasMembership.join(self.a, home: self.r1, in: &$0) }
        inspector(m).deleteRegion()
        XCTAssertEqual(m.scene.regionCount, 1, "r2 survives")
        XCTAssertNil(m.scene.region(r1))
        XCTAssertNotNil(m.scene.node(a))
        XCTAssertNil(m.selection)
    }

    func test_deletingTheRegionIsUndoable() throws {
        let m = model()
        m.withScene { CanvasMembership.join(self.a, home: self.r1, in: &$0) }
        inspector(m).deleteRegion()
        m.undo.undo()
        XCTAssertTrue(try XCTUnwrap(m.scene.region(r1)).livesHere(a),
                      "the membership records die with the region and come back with it")
    }

    /// Every commit is reachable with a stale `regionID` — an undo can take the
    /// region away a frame before the button is pressed. None of them may trap,
    /// and none of them may push a step.
    func test_everyCommitIsANoOpOnARegionThatIsGone() {
        let m = model()
        let i = inspector(m)
        m.withScene { $0.removeRegion(self.r1) }
        let before = m.sceneRevision
        i.commitLabel("Falls")
        i.commitCollapsed(true)
        i.commitBinding("piece-3")
        i.remove(a)
        i.deleteRegion()
        XCTAssertEqual(m.sceneRevision, before)
        XCTAssertFalse(m.undo.canUndo)
    }

    // MARK: - The inspector edits a scene the canvas is still holding open

    /// **A visit to a scrap holds "Edit Scrap" open, and nothing on the
    /// inspector's side of the window closes it.** Select a region's chrome,
    /// double-click a card (which deliberately leaves `selection` alone), then
    /// rename the region: through `CanvasModel.mutate` that rename nests, depth
    /// 2 takes no snapshot, depth 1 registers nothing, and the rename is not on
    /// the stack at all — while the writer's next keystroke carries it into a
    /// step called "Edit Scrap".
    func test_anInspectorEditIsItsOwnStepWithAScrapStillFocused() {
        let m = model()
        m.beginGesture("Edit Scrap")
        m.setScrapText("The fog came down.", for: a)

        inspector(m).commitLabel("Falls at night")
        XCTAssertEqual(m.scene.region(r1)?.label, "Falls at night")

        m.undo.undo()
        XCTAssertEqual(m.scene.region(r1)?.label, "Act II fog",
                       "one ⌘Z takes back the rename")
        XCTAssertEqual(m.scraps[a], "The fog came down.",
                       "and the sentence the writer was in the middle of is not "
                       + "collateral damage")
    }

    /// The other half: the visit RESUMES, so what the writer types after the
    /// inspector edit is still bracketed. Drop the reopen and this run of typing
    /// belongs to no gesture at all.
    func test_theOpenVisitResumesAfterAnInspectorEdit() {
        let m = model()
        m.beginGesture("Edit Scrap")
        m.setScrapText("One.", for: a)
        inspector(m).commitLabel("Falls")
        m.setScrapText("One. Two.", for: a)
        m.endGesture()

        m.undo.undo()
        XCTAssertEqual(m.scraps[a], "One.", "the typing after the rename is its own step…")
        // **This is the assertion that sees the reopen**, and the version without
        // it passed with the reopen deleted (mutation, 2026-07-28): with no
        // gesture open, the second run of typing is registered nowhere at all,
        // so the first ⌘Z lands on the rename's snapshot — which happens to hold
        // "One." too, and every other assertion here is satisfied by the
        // coincidence.
        XCTAssertEqual(m.scene.region(r1)?.label, "Falls",
                       "…and ONLY that. The rename is a step of its own and is "
                       + "still standing after one ⌘Z.")
        m.undo.undo()
        XCTAssertEqual(m.scene.region(r1)?.label, "Act II fog")
        XCTAssertEqual(m.scraps[a], "One.", "and the typing is not collateral")
        m.undo.undo()
        XCTAssertNil(m.scraps[a], "the typing before the rename is the step under that")
    }

    // MARK: - Mounted only beside a live canvas

    /// **The invariant this surface must not break.** After `detach()` the model
    /// still has a store, so a write still reaches disk — but `readSnapshot` and
    /// `applySnapshot` are nil, so `beginGesture` snapshots nothing,
    /// `endGesture` returns on its `guard let before`, and the edit registers no
    /// undo step **silently**.
    ///
    /// A guard inside the inspector was considered and rejected: `store = nil`
    /// would turn the failure from *wrong* to *silently nothing*, which is not
    /// better. The answer is that the inspector is only ever mounted beside a
    /// live canvas — pinned structurally in the two tests below. This one
    /// measures what is on the other side of that rule, so the next author does
    /// not have to rediscover it.
    func test_aDetachedModelTakesTheEditAndRegistersNothing() {
        let m = model()
        m.detach()
        inspector(m).commitLabel("Falls at night")
        XCTAssertEqual(m.scene.region(r1)?.label, "Falls at night",
                       "the write still lands…")
        XCTAssertFalse(m.undo.canUndo,
                       "…and no step is registered for it, which is why the "
                       + "inspector must never outlive the canvas")
    }

    /// The canvas and its inspector are two columns of ONE `binderSegment` case,
    /// so they cannot mount or unmount separately.
    func test_theCanvasAndItsInspectorAreTwoColumnsOfOneSegment() throws {
        let source = try projectWindowSource()
        XCTAssertEqual(occurrences(of: "switch binderSegment {", in: source), 2,
                       "two switches over the segment: the centre column and the "
                       + "inspector. A third would need its own arm here.")

        let arms = canvasArms(in: source)
        XCTAssertEqual(arms.count, 2)
        XCTAssertTrue(arms[0].contains("CanvasView("),
                      "the centre column's `.canvas` arm is the canvas itself")
        XCTAssertTrue(arms[1].contains("canvasInspector("),
                      "and the inspector's `.canvas` arm is the region inspector — "
                      + "move it to any other segment and it can be on screen "
                      + "with no live canvas behind it")

        XCTAssertEqual(occurrences(of: "CanvasView(", in: source), 1)
        XCTAssertEqual(occurrences(of: "RegionInspectorPane(", in: source), 1,
                       "one mount point each; a second would not be gated on the "
                       + "arm above")
        XCTAssertEqual(occurrences(of: "canvasInspector(", in: source), 2,
                       "the declaration and exactly ONE call. A second call is a "
                       + "second mount — and the arm assertions above cannot see "
                       + "it, because they only ask what the canvas arm contains.")
    }

    /// Tripwire 30's rule, one column over: `CanvasModel` is `@Observable` and
    /// `scene` is one stored property that every drag and coast frame writes, so
    /// reading it from `ProjectWindow.body` puts the largest body in the app on
    /// the drag loop.
    func test_theCanvasInspectorArmReadsNothingOffTheModel() throws {
        let source = try projectWindowSource()
        let arm = try XCTUnwrap(declaration(named: "private func canvasInspector(",
                                            in: source))
        XCTAssertTrue(arm.contains("RegionInspectorPane("))
        XCTAssertFalse(arm.contains("canvasModel."),
                       "resolving the selection here re-evaluates ProjectWindow.body "
                       + "at frame rate for the length of every canvas drag — "
                       + "`RegionInspectorPane` does the resolving one leaf down")
    }

    /// The runtime half of the same fact: building what `ProjectWindow.body`
    /// builds registers no observation of the scene.
    func test_buildingThePaneObservesNothingTheDragLoopWrites() {
        let m = model()
        var fired = false
        withObservationTracking {
            _ = RegionInspectorPane(model: m, pieces: [])
        } onChange: {
            fired = true
        }
        m.withScene(persist: false) {
            $0.setRegionFrame(CGRect(x: 40, y: 40, width: 600, height: 400), for: self.r1)
        }
        XCTAssertFalse(fired, "a drag frame must not invalidate the window's body")
    }

    // MARK: - Source helpers

    private func projectWindowSource() throws -> String {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Canvas
            .deletingLastPathComponent()   // MaughamTests
            .deletingLastPathComponent()   // repo
        return try String(
            contentsOf: repoRoot.appendingPathComponent("Maugham/Views/ProjectWindow.swift"),
            encoding: .utf8)
    }

    private func occurrences(of needle: String, in haystack: String) -> Int {
        haystack.components(separatedBy: needle).count - 1
    }

    /// The body of each `case .canvas:` arm, bounded by the next `case` at the
    /// same indentation — unbounded, every arm would contain the whole rest of
    /// the file and the assertions above could not fail.
    private func canvasArms(in source: String) -> [String] {
        source.components(separatedBy: "\n        case .canvas:").dropFirst().map { arm in
            if let end = arm.range(of: "\n        case ") {
                return String(arm[..<end.lowerBound])
            }
            return arm
        }
    }

    /// A member declaration, from its opening line to the closing brace at
    /// member indentation.
    private func declaration(named header: String, in source: String) -> String? {
        guard let start = source.range(of: header) else { return nil }
        let rest = source[start.lowerBound...]
        guard let end = rest.range(of: "\n    }\n") else { return String(rest) }
        return String(rest[..<end.upperBound])
    }
}
