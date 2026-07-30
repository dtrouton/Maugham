import XCTest
@testable import Maugham

/// Naming a line, from the window's other column.
///
/// Fixture: three cards `a`, `b`, `c`; `l1` runs a→b and starts unlabelled,
/// `l2` runs b→c and starts "leads to". The selection opens on `l1`, which is
/// what puts `LineInspector` on screen.
///
/// **The subject of this suite is tripwire 32**, and the shape of its failure is
/// why the assertions below read the step's NAME rather than the scene: an edit
/// that nests into an open "Edit Scrap" registers nothing of its own, and a ⌘Z
/// that closes *and* undoes that bracket satisfies every scene assertion by
/// coincidence.
final class LineInspectorTests: XCTestCase {

    private var root: URL!
    private let a = CanvasNodeID("a")
    private let b = CanvasNodeID("b")
    private let c = CanvasNodeID("c")
    private let l1 = CanvasLineID("l1")
    private let l2 = CanvasLineID("l2")

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("line-inspector-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func scene() -> CanvasScene {
        var s = CanvasScene()
        for (index, id) in [a, b, c].enumerated() {
            s.insert(CanvasNode(id: id, kind: .scrap,
                                origin: CGPoint(x: CGFloat(index) * 400, y: 0),
                                width: 240, cachedHeight: 80))
        }
        s.insertLine(CanvasLine(id: l1, from: a, to: b))
        s.insertLine(CanvasLine(id: l2, from: b, to: c, label: "leads to"))
        return s
    }

    private func model() -> CanvasModel {
        let m = CanvasModel()
        m.attach(projectRoot: root)
        m.withScene { $0 = self.scene() }
        m.selection = .line(l1)
        return m
    }

    private func inspector(_ m: CanvasModel, on line: CanvasLineID? = nil) -> LineInspector {
        LineInspector(model: m, lineID: line ?? l1)
    }

    // MARK: - What counts as a label

    /// Whitespace is **no label**, not a label made of spaces. Stored, one draws
    /// an empty pill on the line for the rest of the canvas's life — the writer
    /// can see it, cannot read it, and clearing the field again is the only way
    /// out, which is not a thing anybody would guess.
    ///
    /// `normalise` is `static` and pure so this rule is reachable without
    /// hosting SwiftUI.
    func test_whitespaceOnlyIsNoLabelRatherThanALabelOfSpaces() {
        XCTAssertNil(LineInspector.normalise("   \n "),
                     "spaces and a newline are not a name")
        XCTAssertNil(LineInspector.normalise(""), "and neither is nothing at all")
        XCTAssertEqual(LineInspector.normalise("  because of the ponchos  "),
                       "because of the ponchos",
                       "the control: a real name survives, trimmed. Without this "
                       + "the two assertions above are satisfied by a `normalise` "
                       + "that returns nil for everything")
        XCTAssertEqual(LineInspector.normalise("because of the ponchos"),
                       "because of the ponchos",
                       "and an already-clean name is handed back unchanged")
    }

    // MARK: - The commit

    func test_committingALabelIsOneUndoStepCalledLabelLine() throws {
        let m = model()
        inspector(m).commitLabel("because of the ponchos")
        XCTAssertEqual(m.scene.line(l1)?.label, "because of the ponchos")

        XCTAssertTrue(m.undo.undoMenuItemTitle.contains("Label Line"),
                      "the Edit menu must name the writer's own act. Got: "
                      + m.undo.undoMenuItemTitle)

        m.undo.undo()
        XCTAssertNotNil(m.scene.line(l1),
                        "⌘Z takes back the NAME. The line is not the label — an "
                        + "undo that removed the line itself would be a second, "
                        + "unasked-for act")
        XCTAssertNil(try XCTUnwrap(m.scene.line(l1)).label, "and only the label went")
        XCTAssertFalse(m.undo.canUndo,
                       "one name, one step — not one per keystroke, which is what "
                       + "the local draft in the view is for")
    }

    func test_theLabelReachesDisk() {
        let m = model()
        inspector(m).commitLabel("because of the ponchos")
        m.flush()
        XCTAssertEqual(CanvasStore(projectRoot: root).load().scene.line(l1)?.label,
                       "because of the ponchos",
                       "the codec round-trips a label and until now only a test "
                       + "could set one")
    }

    func test_clearingTheLabelRemovesItRatherThanStoringEmptyString() throws {
        let m = model()
        m.selection = .line(l2)
        inspector(m, on: l2).commitLabel("   ")

        let line = try XCTUnwrap(m.scene.line(l2))
        XCTAssertNil(line.label,
                     "cleared to nil and not to \"\": an empty string is a label "
                     + "as far as everything downstream is concerned, and the pill "
                     + "would be drawn on the line forever")
        XCTAssertEqual(line.from, b, "the line itself is untouched")
        XCTAssertEqual(line.to, c)
        XCTAssertTrue(m.undo.undoMenuItemTitle.contains("Clear Line Label"),
                      "clearing is its own act and the Edit menu says so — "
                      + "\"Undo Label Line\" over a name that is gone reads as the "
                      + "opposite of what ⌘Z would do. Got: "
                      + m.undo.undoMenuItemTitle)

        m.undo.undo()
        XCTAssertEqual(m.scene.line(l2)?.label, "leads to",
                       "and clearing is its own step, not a silent write")
    }

    /// A name typed into `l1`'s field and committed after the selection has
    /// already moved on lands on `l1`. The field commits on focus loss and on the
    /// selected line changing, and it does not control which of those SwiftUI and
    /// AppKit deliver first.
    func test_aLabelCommitsToTheLineItWasTypedIn() {
        let m = model()
        let showingTheOtherLine = LineInspector(model: m, lineID: l2)
        showingTheOtherLine.commitLabel("because of the ponchos", to: l1)
        XCTAssertEqual(m.scene.line(l1)?.label, "because of the ponchos")
        XCTAssertEqual(m.scene.line(l2)?.label, "leads to",
                       "and not on whichever line is on screen by then")
    }

    /// **Both directions of the change-check.**
    ///
    /// The instrument is the STRUCTURAL counter, because that is what the guard
    /// actually protects. It cannot be the undo stack: `CanvasUndo.endGesture`
    /// already declines to register a gesture that changed nothing, so the ⌘Z
    /// count is identical with the guard deleted. What the guard buys past that
    /// is the rest — no snapshot, no queued disk write, and no canvas redraw for
    /// a commit that did nothing, on a field that commits on every focus loss.
    func test_anUnchangedLabelRegistersNothing() {
        let m = model()
        let i = inspector(m)
        i.commitLabel("leads to")
        let afterTheRealChange = m.sceneRevision

        i.commitLabel("leads to")
        XCTAssertEqual(m.sceneRevision, afterTheRealChange,
                       "the commit on focus loss is the common case and it "
                       + "changed nothing")
        i.commitLabel("  leads to  ")
        XCTAssertEqual(m.sceneRevision, afterTheRealChange,
                       "and it is the NORMALISED value that is compared — trailing "
                       + "space the writer never sees is not a change")

        i.commitLabel("leads away")
        XCTAssertEqual(m.sceneRevision, afterTheRealChange + 1,
                       "the control: a guard that swallows a real change is the "
                       + "same defect wearing the opposite sign, and the canvas "
                       + "draws this label from inside a draw closure where "
                       + "nothing else would get the redraw")
    }

    /// What the writer is owed, which is one ⌘Z per name. **It does not pin the
    /// guard** — see the test above for the instrument that can.
    func test_aNoOpCommitDoesNotCostASecondUndo() {
        let m = model()
        inspector(m).commitLabel("leads to")
        inspector(m).commitLabel("leads to")
        m.undo.undo()
        XCTAssertNil(try XCTUnwrap(m.scene.line(l1)).label,
                     "a commit that changed nothing must not push a step the "
                     + "writer has to press ⌘Z twice to get past")
    }

    // MARK: - Delete, from the pane rather than from the canvas
    //
    // A region could be deleted from this pane from the moment 1C-b shipped.
    // A line arriving with only ⌫ would have made two arms of ONE
    // RegionInspectorPane offer different affordances for the same act — and ⌫
    // needs the event view to hold first responder, so a writer who has just
    // typed a name into the field has to click back onto the canvas first.

    func test_deletingTheLineFromTheInspectorLeavesBothCards() {
        let m = model()
        inspector(m).deleteLine()

        XCTAssertNil(m.scene.line(l1))
        XCTAssertNotNil(m.scene.line(l2), "the other line survives")
        XCTAssertNotNil(m.scene.node(a), "the cards are not the canvas's to delete")
        XCTAssertNotNil(m.scene.node(b))
    }

    /// **The selection must not be left naming a line that is gone.** Every
    /// reader resolves it, `CanvasModel.selectedLine` above all — which is what
    /// decides whether this view is on screen. Left dangling, the writer deletes
    /// a line and goes on looking at its inspector.
    ///
    /// The control is the second assertion: `selectedLine` has to answer nil
    /// *and* the raw selection has to be clear, or a build that relies on the
    /// resolver returning nil for a stale id passes while ⌫ still points at the
    /// dead line.
    func test_deletingTheLineClearsTheSelectionRatherThanLeavingItDangling() {
        let m = model()
        XCTAssertEqual(m.selection, .line(l1), "premise: the line is selected")

        inspector(m).deleteLine()

        XCTAssertNil(m.selection,
                     "the selection still names the deleted line, so ⌫ and the "
                     + "inspector are both pointed at something not in the scene")
        XCTAssertNil(m.selectedLine,
                     "and the pane that resolves it must fall to its empty state")
    }

    /// The discriminator is the step's NAME, for this suite's stated reason: a
    /// test whose only observable is the post-⌘Z scene cannot tell "its own step"
    /// from "folded into the neighbouring one".
    func test_deletingTheLineIsOneUndoStepCalledDeleteLine() throws {
        let m = model()
        inspector(m).deleteLine()

        XCTAssertTrue(m.undo.undoMenuItemTitle.contains("Delete Line"),
                      "the delete is not its own undo step — the Edit menu says "
                      + m.undo.undoMenuItemTitle)

        m.undo.undo()
        let restored = try XCTUnwrap(m.scene.line(l1))
        XCTAssertEqual(restored.from, a, "the line comes back with both its ends")
        XCTAssertEqual(restored.to, b)
    }

    /// Tripwire 32, on the delete path rather than the label path. Nested, the
    /// mutation takes no snapshot at depth 2 and registers nothing at depth 1, so
    /// the delete lands on no step at all and rides into the writer's next
    /// sentence — a ⌘Z aimed at a sentence takes the line with it.
    ///
    /// The premise is asserted rather than described, for the reason the label
    /// version of this test states at length.
    func test_deletingFromTheInspectorWhileAScrapIsFocusedIsItsOwnStep() {
        let m = model()
        m.beginGesture("Edit Scrap")
        m.setScrapText("The fog came down.", for: a)

        XCTAssertTrue(m.isInGesture, "premise: the bracket is open")
        XCTAssertFalse(m.undoManager.canUndo,
                       "premise: the run of typing has registered nothing yet")

        inspector(m).deleteLine()

        XCTAssertTrue(m.undo.undoMenuItemTitle.contains("Delete Line"),
                      "the delete nested into the open \"Edit Scrap\" bracket and "
                      + "registered no step of its own — the Edit menu says "
                      + m.undo.undoMenuItemTitle)
    }

    /// Reachable with a stale `lineID`: an undo, or a ⌫ on the canvas, can take
    /// the line away a frame before the button is pressed. It must not trap and
    /// must not push a step.
    func test_deletingALineThatIsAlreadyGoneIsANoOp() {
        let m = model()
        m.withScene { $0.removeLine(self.l1) }
        let before = m.sceneRevision

        inspector(m).deleteLine()

        XCTAssertEqual(m.sceneRevision, before)
        XCTAssertFalse(m.undo.canUndo,
                       "a delete of a line that is already gone pushed a step the "
                       + "writer has to press ⌘Z past")
    }

    // MARK: - The inspector edits a scene the canvas is still holding open

    /// **The test this whole task exists to keep green, and it goes red the
    /// moment `mutateFromInspector` becomes `mutate`.**
    ///
    /// A visit to a scrap holds "Edit Scrap" open for as long as focus is in it,
    /// and nothing on the inspector's side of the window closes it. Nested, the
    /// commit takes no snapshot at depth 2 and registers nothing at depth 1, so
    /// the name lands on **no undo step at all** and rides into whatever step the
    /// open gesture eventually closes — a ⌘Z aimed at a sentence takes the line's
    /// name with it.
    ///
    /// **The premise is asserted, not described.** A suite of forty-seven tests
    /// in this area stayed green through exactly this defect because every one of
    /// them drove its signal by hand and stated its premise only in a docstring.
    /// So the three lines below say, in the test, that a gesture really is open
    /// and really is holding an unregistered change.
    func test_aCommitFromTheInspectorWhileAScrapIsFocusedIsItsOwnStep() {
        let m = model()
        m.beginGesture("Edit Scrap")
        m.setScrapText("The fog came down.", for: a)

        XCTAssertTrue(m.isInGesture,
                      "premise: the writer is inside a scrap and the bracket is open")
        XCTAssertFalse(m.undoManager.canUndo,
                       "premise: nothing is registered yet — the run of typing "
                       + "lives ONLY in the open gesture, which is what makes a "
                       + "nested commit unrecoverable rather than merely misnamed")
        XCTAssertTrue(m.undo.canUndo,
                      "premise: and that gesture is holding a real change, so "
                      + "closing it registers a step. Without this the two "
                      + "assertions above are also true of a gesture that would "
                      + "register nothing, and the nesting has nothing to nest in")

        inspector(m).commitLabel("because of the ponchos")
        XCTAssertTrue(m.undo.undoMenuItemTitle.contains("Label Line"),
                      "the step on top must be the label's own. Through `mutate` "
                      + "it registers NOTHING and this reads a bare \"Undo\", "
                      + "while every scene assertion below still passes. Got: "
                      + m.undo.undoMenuItemTitle)

        m.undo.undo()
        XCTAssertNil(try XCTUnwrap(m.scene.line(l1)).label, "one ⌘Z takes back the name…")
        XCTAssertEqual(m.scraps[a], "The fog came down.",
                       "…and the sentence in flight is not collateral damage")
    }

    /// The other half: the visit RESUMES, so what the writer types after the
    /// inspector edit is still bracketed. Drop the reopen inside
    /// `mutateFromOutsideTheCanvas` and this run of typing belongs to no gesture
    /// at all.
    func test_theOpenVisitResumesAfterALabelIsCommitted() {
        let m = model()
        m.beginGesture("Edit Scrap")
        m.setScrapText("One.", for: a)
        inspector(m).commitLabel("because of the ponchos")
        m.setScrapText("One. Two.", for: a)
        m.endGesture()

        m.undo.undo()
        XCTAssertEqual(m.scraps[a], "One.", "the typing after the label is its own step…")
        XCTAssertEqual(m.scene.line(l1)?.label, "because of the ponchos",
                       "…and ONLY that. The label is a step of its own and is "
                       + "still standing after one ⌘Z — without the reopen the "
                       + "second run of typing is registered nowhere, so this ⌘Z "
                       + "lands on the label's snapshot instead")
    }

    // MARK: - Which arm of the pane

    /// A `.node` selection is neither a line nor a region — it resolves through
    /// `CanvasModel.selectedNode` instead, to `ScrapInspector` (1C-c2). This
    /// reads the resolvers `RegionInspectorPane` routes on, which is where the
    /// decision actually lives — and evaluates the pane's body on both a line
    /// selection and a card selection, so both arms are exercised rather than
    /// merely written.
    func test_aSelectedCardResolvesToTheScrapInspectorNotTheLineOrRegionArm() {
        let m = model()
        XCTAssertNotNil(m.selectedLine, "the control: a line selection resolves")
        XCTAssertNil(m.selectedRegion)
        _ = RegionInspectorPane(model: m, pieces: [],
                                artifactTitle: { _ in nil }, pieceTitle: { _ in nil },
                                onOpenResearchItem: { _ in }).body

        m.selection = .node(a)
        XCTAssertNil(m.selectedLine, "a card is neither a line…")
        XCTAssertNil(m.selectedRegion, "…nor a region — it is `selectedNode`, "
                     + "which is `ScrapInspector`'s to answer")
        XCTAssertEqual(m.selectedNode?.id, a,
                       "the positive half of this test's name: a card selection "
                       + "resolves through `selectedNode`, which is what routes "
                       + "the pane to `ScrapInspector` rather than the empty "
                       + "state — the two negatives above are equally consistent "
                       + "with falling through to neither, so this is the "
                       + "assertion that tells them apart")
        _ = RegionInspectorPane(model: m, pieces: [],
                                artifactTitle: { _ in nil }, pieceTitle: { _ in nil },
                                onOpenResearchItem: { _ in }).body
    }

    // MARK: - Caller censuses

    /// **A green suite cannot tell a fully-exercised function from a reachable
    /// one.** This area has now shipped three halves that were built, tested and
    /// unreachable — 1C-a's ⌘Z, `CanvasScene.remove`, and
    /// `CanvasMembership.addAppearance` — and every one was found by a caller
    /// count rather than by a test. So the counts are written down.
    func test_theLineInspectorAndItsMutatorBothHaveProductionCallers() throws {
        let files = try CanvasSourceCensus.productionFiles()

        let mounts = files
            .filter { $0.name != "LineInspector.swift" }
            .filter { CanvasSourceCensus.commentsStripped($0.source).contains("LineInspector(") }
            .map(\.name)
            .sorted()
        XCTAssertEqual(mounts, ["RegionInspector.swift"],
                       "if this empties, a writer can select a line and never name "
                       + "it — the inspector exists and nothing mounts it. If it "
                       + "grows, the second mount point is a deliberate edit here.")

        let mutators = files
            .filter { $0.name != "CanvasScene.swift" }
            .filter { CanvasSourceCensus.commentsStripped($0.source).contains(".updateLine(") }
            .map(\.name)
            .sorted()
        XCTAssertEqual(mutators, ["LineInspector.swift"],
                       "`CanvasScene.updateLine` had no production caller at all "
                       + "until this task; the inspector is the only thing that "
                       + "changes a line after it is drawn.")
    }
}
