import XCTest
@testable import Maugham

/// There is no runtime hook that reports a SwiftUI ZStack's z-order, and the
/// failure it guards against — the event view eating click-to-place-caret — is
/// invisible to every other test in this plan while being the first thing a
/// writer hits. So it is pinned at the source, the way `TripwireGrepTests` pins
/// its rules.
///
/// The LIVE half of this task — that the editor really does mount into SwiftUI's
/// own hosting hierarchy on a click, that the responder chain reaches the canvas
/// undo stack from there, and that the writer's words reach disk — is
/// `CanvasViewMountingTests`, which hosts this view in a real window.
final class CanvasCompositionTests: XCTestCase {

    private func canvasViewSource() throws -> String {
        try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()    // MaughamTests/Canvas
            .deletingLastPathComponent()    // MaughamTests
            .deletingLastPathComponent()    // repo root
            .appendingPathComponent("Maugham/Canvas/CanvasView.swift"), encoding: .utf8)
    }

    /// Comment lines are excluded, exactly as
    /// `CanvasRendererTests.test_noFileInTheCanvasAreaDerivesItsOwnRasterScale`
    /// does it. A doc comment that NAMES a modifier is documentation; only code
    /// counts. Without this the file's own layer-order comment is scanned as if
    /// it were source and the count is whatever the prose happens to say.
    private func codeOnly(_ source: String) -> String {
        source.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    /// Just the `body` property, so a search over the whole file cannot find a
    /// "mountedEditor" outside the ZStack and make the z-order assertion
    /// meaningless.
    private func bodySource(_ src: String) throws -> String {
        let start = try XCTUnwrap(src.range(of: "var body: some View"))
        let end = try XCTUnwrap(src.range(of: "private var mountedEditorNodeID"),
                                "the mount gate must be declared after `body`")
        return String(src[start.upperBound..<end.lowerBound])
    }

    /// One declaration, from its name to the next blank line. `codeOnly` has
    /// already dropped the doc comments, so what separates declarations is
    /// exactly the blank lines the author left between them.
    private func declarationSource(_ src: String, named name: String) throws -> String {
        let start = try XCTUnwrap(src.range(of: name), "\(name) is not declared")
        let rest = String(src[start.lowerBound...])
        let end = rest.range(of: "\n\n")?.lowerBound ?? rest.endIndex
        return String(rest[rest.startIndex..<end])
    }

    /// The whole `mountedEditor` property — `isEditorVisible:` is an ARGUMENT to
    /// `ScrapEditorHost`, so a slice that stops at `ScrapEditorHost(` cannot see
    /// it. `load()` is the declaration that follows.
    private func mountedEditorBuilder(_ src: String) throws -> String {
        let start = try XCTUnwrap(src.range(of: "private var mountedEditor: some View"))
        let end = try XCTUnwrap(src.range(of: "private func load()"),
                                "`load()` must follow `mountedEditor`")
        return String(src[start.upperBound..<end.lowerBound])
    }

    /// Two assertions, because either alone is fakeable: the ZStack must place
    /// `mountedEditor` after `CanvasEventView`, and `mountedEditor` must be the
    /// thing that builds a `ScrapEditorHost`.
    func test_theMountedEditorIsInFrontOfTheEventView() throws {
        let src = codeOnly(try canvasViewSource())
        let body = try bodySource(src)
        let event = try XCTUnwrap(body.range(of: "CanvasEventView("),
                                  "CanvasView no longer composes CanvasEventView")
        // The frontmost layer is the LAST thing in the ZStack, so `.backwards`
        // finds the composition slot even if a future edit adds another mention
        // of the name above the event view.
        let slot = try XCTUnwrap(body.range(of: "mountedEditor", options: .backwards),
                                 "CanvasView no longer composes mountedEditor")
        XCTAssertTrue(event.lowerBound < slot.lowerBound,
                      "the event view is in FRONT of the mounted editor, so it eats "
                      + "click-to-place-caret, drag-select and double-click-word — "
                      + "the writer sees 'typing does nothing'")

        // `mountedEditorNodeID` shares this prefix, so match the full signature.
        let declaration = try XCTUnwrap(src.range(of: "private var mountedEditor: some View"))
        let host = try XCTUnwrap(src.range(of: "ScrapEditorHost("),
                                 "CanvasView no longer composes ScrapEditorHost")
        XCTAssertTrue(declaration.lowerBound < host.lowerBound,
                      "the editor must be built inside `mountedEditor`, or the "
                      + "z-order assertion above is checking the wrong symbol")
    }

    func test_theGroundAndTheDrawnLayerDoNotHitTest() throws {
        let src = codeOnly(try canvasViewSource())
        let ground = try XCTUnwrap(src.range(of: "CanvasGround("))
        let canvas = try XCTUnwrap(src.range(of: "Canvas {"))
        let event = try XCTUnwrap(src.range(of: "CanvasEventView("))
        XCTAssertTrue(ground.lowerBound < canvas.lowerBound,
                      "the shader ground must be BENEATH the content (spec §7A.4)")
        XCTAssertTrue(canvas.lowerBound < event.lowerBound)
        let beforeEvents = String(src[src.startIndex..<event.lowerBound])
        XCTAssertEqual(
            beforeEvents.components(separatedBy: ".allowsHitTesting(false)").count - 1, 2,
            "both the ground and the drawn layer must opt out of hit testing, or "
            + "clicks never reach the event view")
    }

    /// The editor must EXIST from the click. §7A.5 licenses a late caret, not
    /// lost keystrokes: gate the mount itself on `isLevel` and the first
    /// character or two of a double-click-and-type reach no editor at all.
    /// No runtime test can see this — the mount is a @ViewBuilder branch on
    /// private @State.
    func test_theEditorMountsOnTheClickSoNoKeystrokeIsLost() throws {
        let src = codeOnly(try canvasViewSource())
        let gate = try declarationSource(src, named: "private var mountedEditorNodeID")
        XCTAssertTrue(gate.contains("editingNodeID"))
        XCTAssertFalse(gate.contains("isLevel"),
                       "the MOUNT is gated on the straighten, so the editor does "
                       + "not exist while the writer is typing into it — only "
                       + "visibleEditorNodeID may read isLevel")

        // The builder mounts off that property, not off the visibility one.
        let builder = try mountedEditorBuilder(src)
        XCTAssertTrue(builder.contains("if let id = mountedEditorNodeID"),
                      "the editor must be built off the MOUNT gate")
        XCTAssertFalse(builder.contains("if let id = visibleEditorNodeID"),
                       "mountedEditor is branching on visibility — the "
                       + "deferred-mount defect wearing the new names")
    }

    /// …and must be INVISIBLE until the card is level. Axis-aligned glyphs at
    /// the unrotated text origin over a card still up to 1.2° off level, with
    /// the drawn text already suppressed, snap straight the instant the writer
    /// clicks — the §7A.2 failure by the route §7A.5 exists to close.
    func test_theEditorIsInvisibleUntilTheCardIsLevel() throws {
        let src = codeOnly(try canvasViewSource())
        let gate = try declarationSource(src, named: "private var visibleEditorNodeID")
        XCTAssertTrue(gate.contains("straighten.isLevel("),
                      "the visibility gate must be its own named property, "
                      + "distinct from the mount gate, and it must read isLevel — "
                      + "otherwise the editor is visible at progress 0 and the "
                      + "text jumps straight")

        let builder = try mountedEditorBuilder(src)
        XCTAssertTrue(builder.contains("isEditorVisible: visibleEditorNodeID == id"),
                      "the editor's visibility must come from the same property "
                      + "the renderer is handed, or the two flip on different frames")
    }

    /// The correctness argument in one assertion: the renderer's text
    /// suppression and the editor's visibility read ONE property, so the swap
    /// reveals nothing that was not already on screen. Two spellings of the
    /// predicate is a frame with both drawing, or a frame with neither.
    func test_theRendererAndTheEditorSwapOnTheSamePredicate() throws {
        let src = codeOnly(try canvasViewSource())
        XCTAssertTrue(src.contains("visibleEditorNodeID: visibleEditorNodeID"),
                      "CanvasRenderer.draw must be handed the VISIBILITY id — "
                      + "passing the mount id suppresses the drawn text while an "
                      + "invisible editor draws nothing in its place")
        XCTAssertEqual(src.components(separatedBy: "straighten.isLevel(").count - 1, 1,
                       "there must be exactly one place the straighten is asked "
                       + "whether the card is level; a second is a second predicate")
    }

    /// I7. The editor forwards a point in its OWN unzoomed space; anchoring the
    /// pinch on it directly zooms about a point the writer never touched.
    func test_theFocusedEditorsPinchAnchorGoesThroughTheGeometryMapper() throws {
        let src = codeOnly(try canvasViewSource())
        XCTAssertTrue(src.contains("ScrapEditorGeometry.viewPoint"),
                      "onMagnify hands back an EDITOR-space point — it must be "
                      + "mapped into canvas space before it anchors a zoom")
    }

    func test_theCanvasIsNotHiddenFromAccessibility() throws {
        let src = try canvasViewSource()
        XCTAssertFalse(src.contains("accessibilityHidden(true)"))
        XCTAssertFalse(src.contains("accessibilityElement(children: .ignore)"),
                       "spec §7A.6: we own the canvas AX tree — ignoring children "
                       + "throws away the mounted editor with it")
    }

    /// Two of Task 8's contracts, and they live in one line of source because
    /// they are one line of source.
    ///
    /// The wash seam was left UNWIRED by Task 8 on purpose:
    /// `CanvasGroundPalette.wash(fromHex:)` is written and tested and nothing
    /// called it. This view is the other half. A wash that silently never
    /// arrives looks exactly like a wash dosed correctly at 4%, so no smoke test
    /// can find it and no screenshot can show it.
    ///
    /// The camera has the same shape of failure: both shader uniforms read from
    /// it on every body evaluation, and handing the ground a default
    /// `CanvasCamera()` makes the grain crawl under a pan again — the bug Task 8
    /// exists to have fixed, invisible to every test in that task because they
    /// construct their own camera.
    ///
    /// Source-level because both are private `@State`. The live half — that the
    /// palette closure is actually pulled when the canvas appears — is
    /// `CanvasViewMountingTests.test_theProjectsPaletteIsPulledWhenTheCanvasAppears`.
    func test_theGroundIsHandedTheLiveCameraAndTheProjectsWash() throws {
        let src = codeOnly(try canvasViewSource())
        XCTAssertTrue(src.contains("CanvasGround(camera: camera, wash: wash)"),
                      "the ground must be handed the LIVE camera and the LIVE "
                      + "wash — a default camera makes the grain crawl under a "
                      + "pan, and neither failure is visible on screen")
        XCTAssertTrue(src.contains("CanvasGroundPalette.wash(fromHex: paletteSwatchHexes())"),
                      "nothing turns the project's palette into a wash, so the "
                      + "ground is untinted for every project and the seam Task 8 "
                      + "built is dead code")
    }

    /// A CENSUS, not an allow-list: exactly one place in `Maugham/Canvas/` puts
    /// anything on the canvas's undo stack, and it is `CanvasUndo.register`.
    ///
    /// The canvas's `UndoManager` has `groupsByEvent` **off**, which is right on
    /// the merits (see `CanvasView.undoManager`) and carries one cost:
    /// `UndoManager` no longer opens an implicit group per event, so a
    /// registration made outside an explicit group **raises** instead of being
    /// quietly absorbed. That manager is vended down the responder chain by
    /// `CanvasEventNSView`, so it is reachable by anything on this surface that
    /// goes looking for an undo manager, and "`CanvasUndo` is the only
    /// registrant" was defended by a comment and by one text-view-specific test.
    ///
    /// This is the area-wide half. `CanvasUndo.register`'s own `groupingLevel`
    /// assertion is the other: this one says WHO may register, that one says the
    /// registration is inside a group. A second registrant is not necessarily
    /// wrong — but it has to be seen, and it has to bracket itself.
    func test_theCanvasRegistersUndoInExactlyOnePlace() throws {
        let area = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Maugham/Canvas")
        let files = try FileManager.default
            .contentsOfDirectory(at: area, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        XCTAssertGreaterThan(files.count, 10,
                             "the canvas source directory did not resolve, so this "
                             + "census is scanning nothing")

        var registrants: [String] = []
        for file in files {
            let hits = codeOnly(try String(contentsOf: file, encoding: .utf8))
                .components(separatedBy: "registerUndo").count - 1
            if hits > 0 { registrants.append("\(file.lastPathComponent)×\(hits)") }
        }
        XCTAssertEqual(registrants, ["CanvasUndo.swift×1"],
                       "something other than CanvasUndo.register registers on the "
                       + "canvas undo stack. With groupsByEvent off, a registration "
                       + "outside an explicit group RAISES rather than being "
                       + "absorbed — and a second registrant also puts one change on "
                       + "the stack twice, which is the defect allowsUndo == false "
                       + "exists to prevent. Found: \(registrants)")
    }
}
