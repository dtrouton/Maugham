// MaughamTests/Editor/PendingPlaceTests.swift
import XCTest
import AppKit
import SwiftUI
import MaughamCore
@testable import Maugham

/// **A place lands on its paragraph the first time** (shell p1 Task 4b).
///
/// Going to a paragraph whose piece the editor does not have opens the piece
/// (`ManuscriptNavigation`); the editor's own receiver has nothing to scroll
/// yet, so the window holds the place on its `EditorControl`
/// (`pendingPlace`, written as `ParagraphNavModifier` writes it: through
/// `ManuscriptNavigation.holdsThePlace` and `.place`) and the editor that
/// loads the piece lands it from `EditorSurface.makeNSView`. Each test mounts
/// the real `EditorSurface`, so the load is the production hook, not a call
/// the test makes; nothing is pressed and nothing waits (tripwire 33).
@MainActor
final class PendingPlaceTests: XCTestCase {
    override class func setUp() { FontWarmup.ensure() }

    // MARK: - Fixture

    static let pieceA = "d_pieceA"
    static let pieceB = "d_pieceB"
    static let structure: [StructureItem] = [
        StructureItem(id: pieceA, title: "A", type: .document, path: "manuscript/a.md"),
        StructureItem(id: pieceB, title: "B", type: .document, path: "manuscript/b.md"),
    ]

    /// Three paragraphs; the ids are the valid alphabet's (tripwire 8).
    static let text = "First paragraph here.\n\nSecond paragraph, the target.\n\nThird and last."
    static let ids = ["a1b2", "c3d4", "e5f6"]

    /// Each paragraph's display range in `text`.
    static func ranges() -> [String: NSRange] {
        var out: [String: NSRange] = [:]
        let ns = text as NSString
        var location = 0
        for (i, paragraph) in text.components(separatedBy: "\n\n").enumerated() {
            let length = (paragraph as NSString).length
            out[ids[i]] = NSRange(location: location, length: length)
            location += length + 2
        }
        precondition(location - 2 == ns.length)
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

    private static func textView(in view: NSView?) -> NSTextView? {
        guard let view else { return nil }
        if let tv = view as? NSTextView { return tv }
        for sub in view.subviews { if let tv = textView(in: sub) { return tv } }
        return nil
    }

    /// What the window's paragraph receiver does with one request, given
    /// what is open (`ParagraphNavModifier.holdingThePlace`): returns the
    /// subject it goes to, having held the place when it must.
    @discardableResult
    private func request(_ payload: [String: Any], current: WindowSubject,
                         control: EditorControl) -> WindowSubject {
        let docId = ManuscriptNavigation.paragraphDocId(payload: payload, current: current,
                                                        structure: Self.structure)
        let next = ManuscriptNavigation.destination(toDocument: docId, current: current)
        if ManuscriptNavigation.holdsThePlace(docId: docId, current: current, next: next,
                                              pending: control.pendingPlace),
           let place = ManuscriptNavigation.place(docId: docId, payload: payload) {
            control.pendingPlace = place
        }
        return next
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
    func test_aPlaceInAnUnopenedPieceLandsOnTheParagraphAfterTheLoad() throws {
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

        // A slugline's line is held and landed the same way: the navigator
        // has put the script on the faces, and the post names no document.
        request(["lineLocation": Self.target.location],
                current: Self.overTheCanvas.with(faces: .item(Self.pieceB)), control: control)
        XCTAssertEqual(control.pendingPlace, .init(docId: Self.pieceB, target: .line(location: Self.target.location)))
        let script = try load(Self.pieceB, control: control)
        XCTAssertEqual(script.caret, Self.target.location, "the slugline's line, on the first click")
        XCTAssertNil(control.pendingPlace)
    }

    /// Two clicks before the piece has loaded: the second is where the writer
    /// lands, whether it names the same piece or another.
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
        let control = EditorControl()
        request(Self.paragraph("c3d4", in: Self.pieceB), current: Self.overTheCanvas, control: control)

        let other = try load(Self.pieceA, control: control)
        XCTAssertNotEqual(other.caret, Self.target.location,
                          "piece A has a c3d4 too, and the place is not landed on it")
        XCTAssertNil(control.pendingPlace, "dropped silently on that load")

        let piece = try load(Self.pieceB, control: control)
        XCTAssertNotEqual(piece.caret, Self.target.location, "a dropped place does not land later")

        // The synchronous receiver on piece A, asked for piece B's paragraph.
        other.window.makeFirstResponder(other.textView)
        let before = other.textView.selectedRange()
        MaughamEvent.post(.maughamNavigateToParagraph, to: .keyWindow,
                          payload: Self.paragraph("c3d4", in: Self.pieceB))
        XCTAssertEqual(other.textView.selectedRange(), before,
                       "a navigation naming another document is that document's editor's")
    }

    /// A paragraph the loaded piece does not have: nothing moves, and the
    /// place is gone.
    func test_aPendingRequestForAMissingParagraphIsDropped() throws {
        let control = EditorControl()
        request(Self.paragraph("zzzz", in: Self.pieceB), current: Self.overTheCanvas, control: control)
        XCTAssertNotNil(control.pendingPlace, "premise: held")
        let control2 = EditorControl()
        let untouched = try load(Self.pieceB, control: control2)

        let m = try load(Self.pieceB, control: control)
        XCTAssertEqual(m.textView.selectedRange(), untouched.textView.selectedRange(),
                       "the caret is where a load with no place leaves it")
        XCTAssertNil(control.pendingPlace, "dropped")

        // A line past the end of the text is dropped the same way.
        control.pendingPlace = .init(docId: Self.pieceB, target: .line(location: 10_000))
        let past = try load(Self.pieceB, control: control)
        XCTAssertEqual(past.textView.selectedRange(), untouched.textView.selectedRange())
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
    /// manuscript editor's place, even when it names the same document id.
    func test_aSecondEditorInTheWindowLeavesThePlaceAlone() throws {
        let control = EditorControl()
        request(Self.paragraph("c3d4", in: Self.pieceB), current: Self.overTheCanvas, control: control)
        let statement = try load(Self.pieceB, control: control, secondEditor: true)
        XCTAssertNotEqual(statement.caret, Self.target.location)
        XCTAssertNotNil(control.pendingPlace, "still waiting for the manuscript editor")
        let manuscript = try load(Self.pieceB, control: control)
        XCTAssertEqual(manuscript.caret, Self.target.location)
    }
}

private extension WindowSubject {
    func with(faces: BinderSubject) -> WindowSubject {
        var copy = self
        copy.faces = faces
        return copy
    }
}
