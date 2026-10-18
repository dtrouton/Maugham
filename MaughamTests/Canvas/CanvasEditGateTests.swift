import XCTest
@testable import Maugham

/// A canvas whose layout file this build refused offers no edits (issue #44) —
/// pinned WINDOWLESSLY, on the pure predicates the view asks (tripwire 33: no
/// synthesised click, no press-then-wait), plus a census that the view and the
/// inspectors really ask them, and ask them BEFORE the act each one guards.
///
/// The model-side half (every verb a no-op, nothing written) is
/// `CanvasModelTests`; the performer's door is `PromotionPerformerTests`.
@MainActor
final class CanvasEditGateTests: XCTestCase {

    // MARK: - The predicates

    /// Every arm answers "yes" on a writable canvas — the control that makes the
    /// read-only "no"s mean something.
    func test_aWritableCanvasIsUntouchedByTheGate() {
        for count in 1...3 {
            XCTAssertEqual(CanvasEditGate.clickCount(count, isReadOnly: false), count)
        }
        XCTAssertTrue(CanvasEditGate.dragBegins(isReadOnly: false))
        XCTAssertTrue(CanvasEditGate.deletes(isReadOnly: false))
        for drop in CanvasEditGate.Drop.allCases {
            XCTAssertTrue(CanvasEditGate.accepts(drop, isReadOnly: false), "\(drop)")
        }
        XCTAssertTrue(CanvasEditGate.offersVerbs(isReadOnly: false))
        XCTAssertTrue(CanvasEditGate.editsValues(isReadOnly: false))
    }

    /// A double (or triple) click is a single click: it selects, and makes,
    /// enters and mounts nothing. A single click still selects — read-only is
    /// not frozen.
    func test_aReadOnlyCanvasTakesADoubleClickAsASingleOne() {
        XCTAssertEqual(CanvasEditGate.clickCount(1, isReadOnly: true), 1,
                       "selection still works")
        XCTAssertEqual(CanvasEditGate.clickCount(2, isReadOnly: true), 1)
        XCTAssertEqual(CanvasEditGate.clickCount(3, isReadOnly: true), 1)
    }

    func test_aReadOnlyCanvasBeginsNoDragAndDeletesNothing() {
        XCTAssertFalse(CanvasEditGate.dragBegins(isReadOnly: true))
        XCTAssertFalse(CanvasEditGate.deletes(isReadOnly: true))
    }

    /// Every drop that would add something springs back; showing a card that
    /// is already there changes nothing, so it stays.
    func test_aReadOnlyCanvasAcceptsOnlyTheRevealDrop() {
        XCTAssertTrue(CanvasEditGate.accepts(.reveal, isReadOnly: true))
        XCTAssertFalse(CanvasEditGate.accepts(.place, isReadOnly: true))
        XCTAssertFalse(CanvasEditGate.accepts(.capture, isReadOnly: true))
        XCTAssertFalse(CanvasEditGate.accepts(.external, isReadOnly: true))
    }

    func test_aReadOnlyCanvasInspectorShowsValuesAndOffersNoVerbs() {
        XCTAssertFalse(CanvasEditGate.offersVerbs(isReadOnly: true))
        XCTAssertFalse(CanvasEditGate.editsValues(isReadOnly: true))
    }

    /// `Promote…` greys out (and ⌘⇧↩ is dropped) for every selection kind on a
    /// read-only canvas. The control is the same arguments with the fact off.
    func test_promoteIsOffOnAReadOnlyCanvas() {
        let a = CanvasNodeID("a")
        let cases: [(CanvasSelection, CanvasNodeKind?)] = [
            (.node(a), .scrap),
            (.node(a), .item(.owned(path: "canvas_assets/image-20260730-121314.png"))),
            (.region(CanvasRegionID("r")), nil),
            (.line(CanvasLineID("l")), nil),
        ]
        for (selection, kind) in cases {
            XCTAssertTrue(CanvasPromotionModifier.isPromotable(
                persona: .plan, selection: selection, nodeKind: kind, isReadOnly: false),
                "control: \(selection)")
            XCTAssertFalse(CanvasPromotionModifier.isPromotable(
                persona: .plan, selection: selection, nodeKind: kind, isReadOnly: true),
                "\(selection)")
        }
    }

    // MARK: - The wiring census

    /// **The view asks the gate, and asks it before the act.** Every predicate
    /// above is exhaustively true with nothing calling it; SwiftUI's drop
    /// delivery and the event view's gestures have no windowless seam, so the
    /// call and its ORDER are what is left to assert. An external drop gated
    /// after `ingest` would strand a copy in `canvas_assets/`; a drag gated after
    /// `interaction.begin` would open an undo bracket nothing closes.
    func test_theCanvasAsksTheGateBeforeEachAct() throws {
        let code = try Self.code(of: "Maugham/Canvas/CanvasView.swift")
        let orders: [(function: String, gate: String, act: String)] = [
            ("func handleClick(", "CanvasEditGate.clickCount(clickCount, isReadOnly: model.isReadOnly)",
             "switch clickTarget(at:"),
            ("func handleDrag(", "CanvasEditGate.dragBegins(isReadOnly: model.isReadOnly)",
             "interaction.begin("),
            ("func deleteSelection(", "CanvasEditGate.deletes(isReadOnly: model.isReadOnly)",
             "model.mutate(\"Delete Region\")"),
            ("func handleDrop(", "CanvasEditGate.accepts(.capture, isReadOnly: model.isReadOnly)",
             "handleCaptureDrop(entryID"),
            ("func handleDrop(", "CanvasEditGate.accepts(.place, isReadOnly: model.isReadOnly)",
             "CanvasDrop.apply("),
            ("func handleExternalDrop(", "CanvasEditGate.accepts(.external, isReadOnly: model.isReadOnly)",
             "CanvasExternalDrop.ingest("),
        ]
        for order in orders {
            XCTAssertEqual(Self.gate(order.gate, runsBefore: order.act,
                                     inFunction: order.function, of: code), true,
                           "\(order.function) must ask \(order.gate) before \(order.act)")
        }
        XCTAssertFalse(code.contains("guard clickCount >= 2"),
                       "the raw click count is not what handleClick acts on")
    }

    /// The inspectors hide their verbs and disable their values through the
    /// gate. One required token per file and kind; a file that drops its call
    /// leaves a live Delete on a canvas whose delete changes nothing.
    func test_theInspectorsAskTheGate() throws {
        let verbs = "CanvasEditGate.offersVerbs(isReadOnly: model.isReadOnly)"
        let values = ".disabled(!CanvasEditGate.editsValues(isReadOnly: model.isReadOnly))"
        let required: [(file: String, token: String, count: Int)] = [
            // Promote…+Delete, Cite a Card, Remove from this region.
            ("Maugham/Canvas/RegionInspector.swift", verbs, 3),
            // Name, Collapsed, Piece.
            ("Maugham/Canvas/RegionInspector.swift", values, 3),
            ("Maugham/Canvas/LineInspector.swift", verbs, 1),
            ("Maugham/Canvas/LineInspector.swift", values, 1),
            ("Maugham/Canvas/ScrapInspector.swift", verbs, 1),
            ("Maugham/Canvas/ScrapInspector.swift", values, 1),
            ("Maugham/Canvas/ItemInspector.swift", verbs, 1),
        ]
        for entry in required {
            let code = try Self.code(of: entry.file)
            XCTAssertEqual(code.components(separatedBy: entry.token).count - 1, entry.count,
                           "\(entry.file): \(entry.token)")
        }
    }

    /// The command's enablement and its `begin()` both pass the model's fact —
    /// a `false` literal there compiles and greys nothing.
    func test_thePromoteCommandPassesTheModelsFact() throws {
        let code = try Self.code(of: "Maugham/Views/ProjectWindow.swift")
        XCTAssertEqual(code.components(separatedBy: "isReadOnly: model.isReadOnly)").count - 1, 2)
        let performer = try Self.code(of: "Maugham/Canvas/PromotionPerformer.swift")
        XCTAssertEqual(Self.gate("PromotionFailure.canvasIsReadOnly(", runsBefore: "try validate(plan)",
                                 inFunction: "func perform(", of: performer), true,
                       "the performer refuses before validating, let alone writing")
    }

    /// **The order checker can say no.** A census that only ever answers true
    /// passes while blind, so it is run over a planted body where the act comes
    /// first, and over one missing the gate altogether.
    func test_theOrderCheckerFiresOnPlantedOffenders() {
        let late = """
        private func handleExternalDrop() -> Bool {
            CanvasExternalDrop.ingest(x)
            guard CanvasEditGate.accepts(.external, isReadOnly: model.isReadOnly) else { return false }
        }
        private func next() {}
        """
        XCTAssertEqual(Self.gate("CanvasEditGate.accepts(.external", runsBefore: "CanvasExternalDrop.ingest(",
                                 inFunction: "func handleExternalDrop(", of: late), false)
        let missing = """
        private func handleExternalDrop() -> Bool {
            CanvasExternalDrop.ingest(x)
        }
        private func next() { CanvasEditGate.accepts(.external, isReadOnly: true) }
        """
        XCTAssertNil(Self.gate("CanvasEditGate.accepts(.external", runsBefore: "CanvasExternalDrop.ingest(",
                               inFunction: "func handleExternalDrop(", of: missing),
                     "a gate in the NEXT function does not count")
    }

    // MARK: - Helpers

    private static func code(of relativePath: String) throws -> String {
        SourceScan.codeLines(of: try CanvasSourceCensus.source(at: relativePath))
            .joined(separator: "\n")
    }

    /// Within `function`'s text (from its declaration to the next `func `),
    /// whether `gate` appears before `act`. Nil when either is absent there.
    private static func gate(_ gate: String, runsBefore act: String,
                             inFunction function: String, of code: String) -> Bool? {
        guard let start = code.range(of: function) else { return nil }
        let rest = code[start.upperBound...]
        let body = rest.range(of: "func ").map { rest[..<$0.lowerBound] } ?? rest
        guard let g = body.range(of: gate), let a = body.range(of: act) else { return nil }
        return g.lowerBound < a.lowerBound
    }
}
