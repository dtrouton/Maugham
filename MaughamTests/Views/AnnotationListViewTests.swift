import XCTest
import SwiftUI
import AppKit
@testable import Maugham
import MaughamCore

/// **`AnnotationListView` mounted on its own** (#116 F11): its read-only
/// wiring, and that its rows are still realised lazily inside the document
/// queue's `LazyVStack` (tripwire 4).
@MainActor
final class AnnotationListViewTests: XCTestCase {

    private var windows: [NSWindow] = []

    override func tearDown() {
        for window in windows { window.orderOut(nil) }
        windows.removeAll()
        super.tearDown()
    }

    // MARK: - The read-only wiring

    /// **`readOnly` offers nothing and does nothing**: no verb survives for any
    /// kind of note, the writer's own included, and every verb is a no-op that
    /// a stray press can call safely. The host's click is the one thing passed
    /// through.
    func test_theReadOnlyWiringOffersNoVerbAndPassesOnlyTheClick() {
        var jumped: [(String, String)] = []
        let wiring = AnnotationRowWiring.readOnly(
            manifest: nil, onJump: { jumped.append(($0, $1.id)) })
        let none = AnnotationRowVerbs(
            acceptOrReject: false, dispose: false, answerAsRuling: false,
            makeChoice: false, keepAsLesson: false, ownNote: false)
        for kind in [AnnotationKind.comment, .suggestedChange, .query, .craftNote] {
            for isOwn in [false, true] {
                XCTAssertEqual(wiring.rowVerbs(Self.note("n", kind: kind), "doc", isOwn), none,
                               "\(kind), own: \(isOwn) — a read-only row offers no verb")
            }
        }
        XCTAssertTrue(wiring.stetFlourishIds.isEmpty)
        XCTAssertNil(wiring.manifest, "the manifest is the host's answer, passed through")

        let note = Self.note("n1")
        wiring.onJump("doc-a", note)
        XCTAssertEqual(jumped.map(\.0), ["doc-a"])
        XCTAssertEqual(jumped.map(\.1), ["n1"])
        // And the default click is a no-op, not a crash.
        AnnotationRowWiring.readOnly(manifest: nil).onJump("doc-a", note)
    }

    // MARK: - Laziness (tripwire 4)

    /// **Five hundred notes realise only the rows on screen.** The list is a
    /// `ForEach`, so inside the document queue's `ScrollView { LazyVStack }`
    /// it must stay lazy: `rowVerbs` is asked once per row the stack realises,
    /// which makes it the counter. Mounted in the queue's exact container,
    /// with nothing pressed or scrolled.
    func test_fiveHundredNotesRealiseOnlyTheRowsOnScreen() {
        let counter = Counter()
        let notes = (0..<500).map { Self.note("n\($0)") }
        mount(ScrollView {
            LazyVStack(spacing: 0) {
                AnnotationListView(
                    annotations: notes, docId: "doc", document: nil,
                    livePids: [], ledgerText: nil, wiring: counter.wiring)
            }
        })
        XCTAssertGreaterThan(counter.realised.count, 0,
                             "control: the stack realised the rows on screen")
        XCTAssertLessThan(counter.realised.count, 60,
                          "a 400pt viewport realised \(counter.realised.count) of 500 "
                          + "rows: the list is no longer lazy inside the queue's stack")
    }

    /// **The instrument's control**: the same list in an eager `VStack`
    /// realises every row, so the count above is a count of realised rows and
    /// not of something else.
    func test_control_anEagerStackRealisesEveryRow() {
        let counter = Counter()
        let notes = (0..<80).map { Self.note("n\($0)") }
        mount(ScrollView {
            VStack(spacing: 0) {
                AnnotationListView(
                    annotations: notes, docId: "doc", document: nil,
                    livePids: [], ledgerText: nil, wiring: counter.wiring)
            }
        })
        XCTAssertEqual(counter.realised.count, 80)
    }

    // MARK: - Fixture

    /// Counts the rows a stack realises, by the `rowVerbs` question each row
    /// asks once when it is built.
    private final class Counter {
        var realised: Set<String> = []
        lazy var wiring: AnnotationRowWiring = {
            let base = AnnotationRowWiring.readOnly(manifest: nil)
            return AnnotationRowWiring(
                localName: base.localName, stetFlourishIds: base.stetFlourishIds,
                manifest: nil,
                rowVerbs: { [unowned self] note, docId, isOwn in
                    self.realised.insert(note.id)
                    return base.rowVerbs(note, docId, isOwn)
                },
                onToggleSelection: base.onToggleSelection,
                onAccept: base.onAccept, onReject: base.onReject, onStet: base.onStet,
                onTriage: base.onTriage, onArchive: base.onArchive, onReply: base.onReply,
                onAnswerAsRuling: base.onAnswerAsRuling, onMakeChoice: base.onMakeChoice,
                onKeepAsLesson: base.onKeepAsLesson, onEdit: base.onEdit,
                onWithdraw: base.onWithdraw, onRevert: base.onRevert,
                onReopen: base.onReopen, onJump: base.onJump)
        }()
    }

    private func mount(_ view: some View) {
        let window = TestWindow.mount(AnyView(view), size: CGSize(width: 320, height: 400))
        windows.append(window)
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
    }

    private static func note(_ id: String, kind: AnnotationKind = .comment) -> Annotation {
        Annotation(
            id: id, kind: kind, paragraphId: nil, body: "Note \(id).",
            suggestedText: kind == .suggestedChange ? "x" : nil, priorText: nil,
            createdAt: Date(timeIntervalSince1970: 0), createdBySession: nil,
            status: .open, userResponse: nil, resolvedAt: nil, isStale: false)
    }
}
