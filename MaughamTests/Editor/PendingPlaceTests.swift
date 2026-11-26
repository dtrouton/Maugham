// MaughamTests/Editor/PendingPlaceTests.swift
import XCTest
import AppKit
import SwiftUI
import MaughamCore
@testable import Maugham

/// **A place lands on its paragraph the first time** (shell p1 Task 4b).
///
/// Going to a paragraph whose piece the window's manuscript editor does not
/// have opens the piece (`ManuscriptNavigation`); the editor's own receiver
/// has nothing to scroll yet, so the window holds the place on its
/// `EditorControl` (`pendingPlace`, through production's
/// `ManuscriptNavigation.holdingThePlace`, the one call `ParagraphNavModifier`
/// makes) and the editor that loads the piece lands it from
/// `EditorSurface.makeNSView`. Each test mounts the real `EditorSurface`, so
/// the load is the production hook, not a call the test makes; an unload is
/// production's `detach()` (what `dismantleNSView` runs). Nothing is pressed
/// and nothing waits (tripwire 33).
@MainActor
final class PendingPlaceTests: XCTestCase {
    override class func setUp() { FontWarmup.ensure() }

    // MARK: - Fixture

    static let pieceA = "d_pieceA"
    static let pieceB = "d_pieceB"
    static let part = "g_part"
    static let structure: [StructureItem] = [
        StructureItem(id: pieceA, title: "A", type: .document, path: "manuscript/a.md"),
        StructureItem(id: pieceB, title: "B", type: .document, path: "manuscript/b.md"),
        StructureItem(id: part, title: "Part", type: .group, children: []),
    ]

    /// Three paragraphs; the ids are the valid alphabet's (tripwire 8).
    static let text = "First paragraph here.\n\nSecond paragraph, the target.\n\nThird and last."
    static let ids = ["a1b2", "c3d4", "e5f6"]

    /// Each paragraph's display range in `text`.
    static func ranges() -> [String: NSRange] {
        var out: [String: NSRange] = [:]
        var location = 0
        for (i, paragraph) in text.components(separatedBy: "\n\n").enumerated() {
            let length = (paragraph as NSString).length
            out[ids[i]] = NSRange(location: location, length: length)
            location += length + 2
        }
        return out
    }

    static var target: NSRange { ranges()["c3d4"]! }

    final class Box { var text: String; init(_ t: String) { text = t } }

    struct Mounted {
        let window: KeyTestWindow
        let textView: NSTextView
        let coordinator: EditorCoordinator
        var caret: Int { textView.selectedRange().location }
    }

    /// The editor loading `docId` — a fresh `EditorSurface`, as `EditorHost`'s
    /// `.id(path)` makes one per document — over the window's `control`.
    private func load(_ docId: String?, control: EditorControl,
                      secondEditor: Bool = false) throws -> Mounted {
        let box = Box(Self.text)
        let binding = Binding(get: { box.text }, set: { box.text = $0 })
        var configuration = EditorSurfaceConfiguration(
            presentation: .init(theme: .light, typography: .defaults, mode: ProseMode(),
                                typewriterScroll: false, sentenceFocus: false,
                                paragraphFocus: false, showElementGutter: false),
            control: control)
        let ranges = Self.ranges()
        configuration.paragraphProviders.documentId = docId
        configuration.paragraphProviders.paragraphRangeProvider = { ranges[$0] }
        configuration.isSecondEditorInItsWindow = secondEditor
        let window = TestWindow.mount(EditorSurface(text: binding, configuration: configuration),
                                      size: CGSize(width: 700, height: 500),
                                      as: KeyTestWindow.self)
        addTeardownBlock { @MainActor in
            window.reportsKey = false
            window.close()
        }
        let textView = try XCTUnwrap(Self.textView(in: window.contentView))
        let coordinator = try XCTUnwrap(textView.delegate as? EditorCoordinator)
        return Mounted(window: window, textView: textView, coordinator: coordinator)
    }

    /// The editor taken down — what leaving the piece (the canvas, a research
    /// item) does to it: `dismantleNSView` → `detach()`.
    private func unload(_ m: Mounted) {
        m.coordinator.detach()
        m.window.reportsKey = false
    }

    /// Where a load with no place leaves the caret.
    private func baselineCaret() throws -> Int {
        let m = try load(Self.pieceB, control: EditorControl())
        defer { unload(m) }
        return m.caret
    }

    private static func textView(in view: NSView?) -> NSTextView? {
        guard let view else { return nil }
        if let tv = view as? NSTextView { return tv }
        for sub in view.subviews { if let tv = textView(in: sub) { return tv } }
        return nil
    }

    /// The window's receiver, as production runs it.
    @discardableResult
    private func request(_ payload: [String: Any], current: WindowSubject,
                         control: EditorControl) -> WindowSubject {
        ManuscriptNavigation.holdingThePlace(payload: payload, current: current,
                                             structure: Self.structure, control: control)
    }

    private static func paragraph(_ id: String, in docId: String, offset: Int? = nil) -> [String: Any] {
        var payload: [String: Any] = ["paragraph_id": id, ManuscriptNavigation.docIdKey: docId]
        if let offset { payload[MaughamEvent.paragraphOffsetKey] = offset }
        return payload
    }

    private static let overTheCanvas = WindowSubject(open: .canvas, faces: .item(pieceA))

    // MARK: - The contract

    /// The first click from the canvas: the piece opens, and the editor that
    /// loads it lands on the paragraph, at the offset, with the text focused.
    /// Taken once: a reload of the piece lands nothing again.
    func test_aPlaceInAnUnopenedPieceLandsOnTheParagraphAfterTheLoad() throws {
        let baseline = try baselineCaret()
        let control = EditorControl()
        let next = request(Self.paragraph("c3d4", in: Self.pieceB, offset: 7),
                           current: Self.overTheCanvas, control: control)
        XCTAssertEqual(next.open, .item(Self.pieceB), "premise: the place opens its piece")
        XCTAssertEqual(control.pendingPlace,
                       .init(docId: Self.pieceB, target: .paragraph(id: "c3d4", offset: 7)),
                       "no editor has the piece, so the window holds the place")

        let m = try load(Self.pieceB, control: control)
        XCTAssertEqual(m.textView.selectedRange(), NSRange(location: Self.target.location + 7, length: 0),
                       "the load lands the caret on the paragraph, at the offset")
        XCTAssertNil(control.pendingPlace, "taken once")
        XCTAssertEqual(control.mountedDocumentId, Self.pieceB, "the window knows its editor has B")

        unload(m)
        XCTAssertNil(control.mountedDocumentId)
        let again = try load(Self.pieceB, control: control)
        XCTAssertEqual(again.caret, baseline, "a consumed place never lands again")
    }

    /// Two clicks before the piece has loaded: the second is where the writer
    /// lands.
    func test_aLaterRequestReplacesAPendingOne() throws {
        let control = EditorControl()
        let opened = request(Self.paragraph("a1b2", in: Self.pieceB),
                             current: Self.overTheCanvas, control: control)
        // The piece is now open but not yet loaded: a second place in it still
        // waits, and replaces the first.
        request(Self.paragraph("c3d4", in: Self.pieceB), current: opened, control: control)
        XCTAssertEqual(control.pendingPlace,
                       .init(docId: Self.pieceB, target: .paragraph(id: "c3d4", offset: nil)),
                       "last act wins")

        let m = try load(Self.pieceB, control: control)
        XCTAssertEqual(m.caret, Self.target.location, "the later request's paragraph, not the first's")
        XCTAssertNil(control.pendingPlace)
    }

    /// A place held for one piece never lands on another — not even on a
    /// paragraph with the same id — and the load that is not its piece drops
    /// it, so it does not land later either. The editor on the other piece
    /// leaves a navigation that names a different document alone.
    func test_aPendingRequestNeverFiresOnADifferentDocument() throws {
        let baseline = try baselineCaret()
        let control = EditorControl()
        request(Self.paragraph("c3d4", in: Self.pieceB), current: Self.overTheCanvas, control: control)

        let other = try load(Self.pieceA, control: control)
        XCTAssertEqual(other.caret, baseline,
                       "piece A has a c3d4 too, and the place is not landed on it")
        XCTAssertNil(control.pendingPlace, "dropped silently on that load")

        // The synchronous receiver on piece A, asked for piece B's paragraph.
        other.window.makeFirstResponder(other.textView)
        let before = other.textView.selectedRange()
        MaughamEvent.post(.maughamNavigateToParagraph, to: .keyWindow,
                          payload: Self.paragraph("c3d4", in: Self.pieceB))
        XCTAssertEqual(other.textView.selectedRange(), before,
                       "a navigation naming another document is that document's editor's")

        unload(other)
        let piece = try load(Self.pieceB, control: control)
        XCTAssertEqual(piece.caret, baseline, "a dropped place does not land later")
    }

    /// A paragraph the loaded piece does not have: nothing moves, and the
    /// place is gone.
    func test_aPendingRequestForAMissingParagraphIsDropped() throws {
        let baseline = try baselineCaret()
        let control = EditorControl()
        request(Self.paragraph("zzzz", in: Self.pieceB), current: Self.overTheCanvas, control: control)
        XCTAssertNotNil(control.pendingPlace, "premise: held")

        let m = try load(Self.pieceB, control: control)
        XCTAssertEqual(m.caret, baseline, "the caret is where a load with no place leaves it")
        XCTAssertNil(control.pendingPlace, "dropped")
        unload(m)

        // A line past the end of the text is dropped the same way.
        control.pendingPlace = .init(docId: Self.pieceB, target: .line(location: 10_000))
        let past = try load(Self.pieceB, control: control)
        XCTAssertEqual(past.caret, baseline)
        XCTAssertNil(control.pendingPlace)
    }

    /// The piece already open and loaded: nothing is held, and the editor's
    /// own receiver lands the paragraph at once, as it always has.
    func test_aPlaceInTheOpenPieceStillScrollsSynchronously() throws {
        let control = EditorControl()
        let m = try load(Self.pieceB, control: control)
        m.window.makeFirstResponder(m.textView)
        let open = WindowSubject(open: .item(Self.pieceB), faces: .item(Self.pieceB))
        let payload = Self.paragraph("c3d4", in: Self.pieceB)

        let next = request(payload, current: open, control: control)
        XCTAssertEqual(next, open, "premise: nothing to open")
        XCTAssertNil(control.pendingPlace, "the editor has the piece: nothing is held")

        MaughamEvent.post(.maughamNavigateToParagraph, to: .keyWindow, payload: payload)
        XCTAssertEqual(m.textView.selectedRange(), NSRange(location: Self.target.location, length: 0),
                       "landed in the same turn as the post")
    }

    /// The window's second editor (a statement pane) never takes the
    /// manuscript editor's place, even when it names the same document id,
    /// and never claims to be the window's manuscript editor.
    func test_aSecondEditorInTheWindowLeavesThePlaceAlone() throws {
        let control = EditorControl()
        request(Self.paragraph("c3d4", in: Self.pieceB), current: Self.overTheCanvas, control: control)
        let statement = try load(Self.pieceB, control: control, secondEditor: true)
        XCTAssertNotEqual(statement.caret, Self.target.location)
        XCTAssertNotNil(control.pendingPlace, "still waiting for the manuscript editor")
        XCTAssertNil(control.mountedDocumentId)
        let manuscript = try load(Self.pieceB, control: control)
        XCTAssertEqual(manuscript.caret, Self.target.location)
    }

    // MARK: - Fix round 1

    /// **I1: the scene navigator writes `open` itself before it posts**, over
    /// the Book, a research item, a figure, the Inbox and the palette — so the
    /// subject has not changed when the receiver runs. The line is held
    /// because the EDITOR does not have the script, and the first click lands.
    func test_aSluglineOverAnyCentreLandsTheFirstTime() throws {
        let centres: [BinderSubject] = [.project, .research("r1"), .figure("f1"), .inbox, .palette]
        for centre in centres {
            let control = EditorControl()
            let before = WindowSubject(open: centre, faces: centre)
            // The pane's order: the subject write, then the post.
            let written = SceneNavigatorPane.subject(before, whenNavigatingTo: Self.pieceB,
                                                     structure: Self.structure, projectType: .screenplay)
            XCTAssertEqual(written.open, .item(Self.pieceB), "premise over \(centre): the pane opened the script")
            let next = request(["lineLocation": Self.target.location], current: written, control: control)
            XCTAssertEqual(next, written, "premise over \(centre): the receiver has nothing left to open")
            XCTAssertEqual(control.pendingPlace,
                           .init(docId: Self.pieceB, target: .line(location: Self.target.location)),
                           "over \(centre), the line is held for the editor")

            let script = try load(Self.pieceB, control: control)
            XCTAssertEqual(script.caret, Self.target.location, "over \(centre), the first click lands")
            unload(script)
        }
    }

    /// **I2: the window leaves the piece before it loads** — the place is
    /// dropped, and a later, ordinary open of the piece lands nothing. A move
    /// that keeps the piece open keeps it.
    func test_aPlaceIsDroppedWhenTheWindowLeavesItsPieceBeforeTheLoad() throws {
        let baseline = try baselineCaret()
        let control = EditorControl()
        let opened = request(Self.paragraph("c3d4", in: Self.pieceB), current: Self.overTheCanvas,
                             control: control)
        ManuscriptNavigation.openChanged(to: opened.open, control: control)
        XCTAssertNotNil(control.pendingPlace, "opening the piece itself keeps the place")

        ManuscriptNavigation.openChanged(to: .canvas, control: control)
        XCTAssertNil(control.pendingPlace, "the window left the piece: the load was abandoned")

        let later = try load(Self.pieceB, control: control)
        XCTAssertEqual(later.caret, baseline, "an hour later, an ordinary open lands nothing")

        // **And the window asks it** (shell p1 final fix): the drop above is
        // inert unless `ParagraphNavModifier` calls it whenever `open`
        // changes. Deleting that line left every test green.
        let modifier = try SourceTree.sourceOfType("ParagraphNavModifier", under: ["Maugham"])
        let code = modifier.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.hasPrefix("//") }
        let change = try XCTUnwrap(code.firstIndex { $0.hasPrefix(".onChange(of: subject.open)") },
                                   "the window watches `open`")
        XCTAssertTrue(code[change...].prefix(3).contains {
            $0.contains("ManuscriptNavigation.openChanged(to: open, control: editorControl)")
        }, "a change of `open` drops a place whose piece the window has left")
    }

    /// **I2: a refused load drops its place** — and only its own. Production's
    /// refusal arm (`EditorHost.loadDocumentIfNeeded`'s `catch`) asks it.
    func test_aRefusedLoadDropsThePlace() throws {
        let control = EditorControl()
        request(Self.paragraph("c3d4", in: Self.pieceB), current: Self.overTheCanvas, control: control)
        control.dropPendingPlace(naming: Self.pieceA)
        XCTAssertNotNil(control.pendingPlace, "another piece's refusal leaves it")
        control.dropPendingPlace(naming: Self.pieceB)
        XCTAssertNil(control.pendingPlace, "its own piece's refusal drops it")

        let load = try SourceTree.declaration(named: "func loadDocumentIfNeeded(", under: "Maugham")
        let refusal = try XCTUnwrap(load.range(of: "} catch {"), "the load's refusal arm")
        XCTAssertTrue(load[refusal.upperBound...].contains("control.dropPendingPlace(naming: item.id)"),
                      "every refusal of the load drops the piece's place")
    }

    /// **I2: nothing is held for an id no editor will load** (a Part), and a
    /// lingering place for the open piece cannot renew itself: with the
    /// editor on the piece, nothing is held.
    func test_aPlaceThatNoEditorWillLoadIsNotHeld() throws {
        let control = EditorControl()
        request(Self.paragraph("c3d4", in: Self.part), current: Self.overTheCanvas, control: control)
        XCTAssertNil(control.pendingPlace, "a Part loads no editor")
        request(Self.paragraph("c3d4", in: "d_gone"), current: Self.overTheCanvas, control: control)
        XCTAssertNil(control.pendingPlace, "nor does an id the book no longer has")
    }

    /// The window's record of its editor survives the predecessor's detach
    /// when a `.id(path)` swap makes the new surface first.
    func test_theEditorsRecordSurvivesItsPredecessorsDetach() throws {
        let control = EditorControl()
        let old = try load(Self.pieceA, control: control)
        let new = try load(Self.pieceB, control: control)
        unload(old)
        XCTAssertEqual(control.mountedDocumentId, Self.pieceB)
        unload(new)
        XCTAssertNil(control.mountedDocumentId)
    }
}
