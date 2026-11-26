import XCTest
import AppKit
import SwiftUI
import MaughamCore
@testable import Maugham

/// **A failed promotion never leaves Brief's intent editor over a closed
/// `Document`** (shell p3 final wave, I3).
///
/// `promotePieceToProject` withdraws and closes the piece's live intent
/// `Document` before it moves the file. The host that owned it was not told,
/// so when the promotion failed after that step the editor stayed mounted
/// over a husk: `setFullText` refused every keystroke and nothing said so.
///
/// Now the promotion holds the intent's open gate for its whole run, and a
/// host whose `Document` is withdrawn from under it drops to its placeholder
/// and loads again under the gate — after a failure, the restored statement.
@MainActor
final class PromotionFailureRebindsIntentTests: XCTestCase {

    func test_aFailedPromotionLeavesGoingForsEditorOnALiveDocument() async throws {
        let temp = TempDirectory()
        addTeardownBlock { temp.cleanup() }
        let collection = try await ProjectFactory.createCollectionProject(
            named: "FailedPromote", in: temp.url)
        let store = try await ProjectStore.load(from: collection)
        let documentStore = try await DocumentStore.open(url: collection)
        store.documentStore = documentStore
        documentStore.projectStore = store
        let piece = try await store.addLoosePiece(title: "Story A", format: .markdown)
        let statement = try await store.createStatement(kind: .intent, scope: .document(piece.id))
        addTeardownBlock { await documentStore.close() }

        // Brief's Going for, editing face: the intent's own editor, mounted.
        let preferences = UserPreferences(defaults: UserDefaults(suiteName: "promote-\(UUID())")!)
        let view = GoingForView(
            store: store, documentStore: documentStore, scope: .document(piece.id),
            isRead: true, essay: nil, marks: [], mayEdit: true, inTheCentre: false,
            posture: Posture(.unrestricted), onOpenInCentre: {}, onShowStrain: { _ in })
            .environment(preferences)
        let window = TestWindow.mount(view, size: CGSize(width: 400, height: 600))
        addTeardownBlock { @MainActor in window.contentView = NSView(frame: .zero) }
        await pumpUntil(deadline: 5) { store.openStatementDocument(id: statement.id) != nil }
        let first = try XCTUnwrap(store.openStatementDocument(id: statement.id),
                                  "premise: the editor bound the intent")

        // A promotion that fails after its close: the destination's parent is
        // a regular file, so staging cannot begin.
        let blocker = temp.url.appendingPathComponent("not-a-folder")
        try "x".write(to: blocker, atomically: true, encoding: .utf8)
        do {
            _ = try await store.promotePieceToProject(
                pieceId: piece.id, destination: blocker.appendingPathComponent("Story A"))
            XCTFail("premise: the promotion fails")
        } catch {}
        XCTAssertTrue(first.isClosed, "premise: the promotion closed the editor's Document")

        // The host re-binds a live Document for the statement.
        await pumpUntil(deadline: 5) {
            if let live = store.openStatementDocument(id: statement.id) { return live !== first }
            return false
        }
        let rebound = try XCTUnwrap(store.openStatementDocument(id: statement.id),
                                    "the editor is left over a closed Document: typing goes nowhere")
        XCTAssertFalse(rebound.isClosed)

        // And typing lands.
        let textView = try XCTUnwrap(Self.textViews(in: window).first)
        let words = "Still going for this."
        textView.setSelectedRange(NSRange(location: (textView.string as NSString).length, length: 0))
        if textView.shouldChangeText(in: textView.selectedRange(), replacementString: words) {
            textView.textStorage?.replaceCharacters(in: textView.selectedRange(), with: words)
            textView.didChangeText()
        }
        await pumpUntil(deadline: 3) { rebound.displayText.contains(words) }
        XCTAssertTrue(rebound.displayText.contains(words),
                      "a keystroke after the failed promotion reaches the statement")
    }

    /// The pure half: a mounted host whose bound `Document` is no longer the
    /// one registered has been withdrawn from under; one not mounted, or
    /// holding none, has not.
    func test_whenAHostCountsAsWithdrawnFrom() async throws {
        let temp = TempDirectory()
        addTeardownBlock { temp.cleanup() }
        let url = temp.url.appendingPathComponent("w.md")
        try "".write(to: url, atomically: true, encoding: .utf8)
        let a = try await Document.load(url: url, device: "test", session: "s", presenter: nil)
        addTeardownBlock { await a.close() }
        XCTAssertTrue(StatementEditorHost.wasWithdrawn(bound: a, registered: nil, mounted: true))
        XCTAssertFalse(StatementEditorHost.wasWithdrawn(bound: a, registered: a, mounted: true))
        XCTAssertFalse(StatementEditorHost.wasWithdrawn(bound: a, registered: nil, mounted: false),
                       "the host's own close (it unmounts first) is not a withdrawal")
        XCTAssertFalse(StatementEditorHost.wasWithdrawn(bound: nil, registered: nil, mounted: true),
                       "an empty editor before its mint holds nothing to lose")
    }

    private static func textViews(in window: NSWindow) -> [MaughamTextView] {
        var found: [MaughamTextView] = []
        func walk(_ view: NSView) {
            if let hit = view as? MaughamTextView { found.append(hit) }
            view.subviews.forEach(walk)
        }
        if let root = window.contentView { walk(root) }
        return found
    }
}
