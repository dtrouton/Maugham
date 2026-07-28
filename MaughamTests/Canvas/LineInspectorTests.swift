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
        XCTAssertNil(m.scene.line(l1)?.label, "and only the label went")
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
        XCTAssertNil(m.scene.line(l1)?.label,
                     "a commit that changed nothing must not push a step the "
                     + "writer has to press ⌘Z twice to get past")
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
        XCTAssertNil(m.scene.line(l1)?.label, "one ⌘Z takes back the name…")
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

    /// A `.node` selection gets the same empty state as no selection at all: a
    /// scrap inspector is not this slice's, and a stub one would be a surface
    /// with nothing to say.
    ///
    /// This reads the two resolvers `RegionInspectorPane` routes on, which is
    /// where the decision actually lives — and evaluates the pane's body on a
    /// line selection, so the new arm is exercised rather than merely written.
    func test_aSelectedCardResolvesToNeitherInspector() {
        let m = model()
        XCTAssertNotNil(m.selectedLine, "the control: a line selection resolves")
        XCTAssertNil(m.selectedRegion)
        _ = RegionInspectorPane(model: m, pieces: []).body

        m.selection = .node(a)
        XCTAssertNil(m.selectedLine, "a card is neither a line…")
        XCTAssertNil(m.selectedRegion, "…nor a region, so the pane falls through "
                     + "to the empty state")
        _ = RegionInspectorPane(model: m, pieces: []).body
    }

    // MARK: - Caller censuses

    /// **A green suite cannot tell a fully-exercised function from a reachable
    /// one.** This area has now shipped three halves that were built, tested and
    /// unreachable — 1C-a's ⌘Z, `CanvasScene.remove`, and
    /// `CanvasMembership.addAppearance` — and every one was found by a caller
    /// count rather than by a test. So the counts are written down.
    func test_theLineInspectorAndItsMutatorBothHaveProductionCallers() throws {
        let files = try productionFiles()

        let mounts = files
            .filter { $0.name != "LineInspector.swift" }
            .filter { commentsStripped($0.source).contains("LineInspector(") }
            .map(\.name)
            .sorted()
        XCTAssertEqual(mounts, ["RegionInspector.swift"],
                       "if this empties, a writer can select a line and never name "
                       + "it — the inspector exists and nothing mounts it. If it "
                       + "grows, the second mount point is a deliberate edit here.")

        let mutators = files
            .filter { $0.name != "CanvasScene.swift" }
            .filter { commentsStripped($0.source).contains(".updateLine(") }
            .map(\.name)
            .sorted()
        XCTAssertEqual(mutators, ["LineInspector.swift"],
                       "`CanvasScene.updateLine` had no production caller at all "
                       + "until this task; the inspector is the only thing that "
                       + "changes a line after it is drawn.")
    }

    // MARK: - Source helpers

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Canvas
            .deletingLastPathComponent()   // MaughamTests
            .deletingLastPathComponent()   // repo
    }

    private func productionFiles() throws -> [(name: String, source: String)] {
        let app = repoRoot.appendingPathComponent("Maugham")
        let walker = FileManager.default.enumerator(at: app, includingPropertiesForKeys: nil)
        var out: [(String, String)] = []
        while let url = walker?.nextObject() as? URL {
            guard url.pathExtension == "swift" else { continue }
            out.append((url.lastPathComponent, try String(contentsOf: url, encoding: .utf8)))
        }
        XCTAssertGreaterThan(out.count, 100,
                             "the walk found almost nothing — a caller census over "
                             + "an empty tree passes for the wrong reason")
        return out
    }

    /// Line and block comments removed, so a doc comment naming a symbol is not
    /// read as using it. Both files censused above discuss the other at length in
    /// prose, which is the whole point of them.
    private func commentsStripped(_ source: String) -> String {
        var out = ""
        var inBlock = false
        for line in source.components(separatedBy: "\n") {
            var line = Substring(line)
            if inBlock {
                guard let end = line.range(of: "*/") else { continue }
                line = line[end.upperBound...]
                inBlock = false
            }
            while let start = line.range(of: "/*") {
                if let end = line.range(of: "*/", range: start.upperBound..<line.endIndex) {
                    line = line[..<start.lowerBound] + line[end.upperBound...]
                } else {
                    line = line[..<start.lowerBound]
                    inBlock = true
                }
            }
            if let slashes = line.range(of: "//") { line = line[..<slashes.lowerBound] }
            out += line + "\n"
        }
        return out
    }
}
