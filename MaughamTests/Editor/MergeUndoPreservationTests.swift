import XCTest
import AppKit
import MaughamCore
@testable import Maugham

/// Task 7 — E3(b), conservative slice: a PURE-APPEND peer merge must preserve
/// the writer's ⌘Z stack; any merge that touches an existing paragraph must
/// keep the D1-consistent clear (ADR 0023 §2).
///
/// `Document.handleExternalLogChange` publishes merged state via
/// `recomputeDisplayText` → the editor's next update pass →
/// `applyExternalText(preserveUndoStack:)`. Every buffer replace clears the
/// native typing-undo stack (the v0.16.0 ⌘Z EXC_BAD_ACCESS class) UNLESS the
/// Document armed `_undoCoherentApplyPending`. Before this fix the merge never
/// armed it, so a remote peer's op — even one appending a new paragraph on an
/// unrelated part of the doc — wiped the entire ⌘Z stack.
///
/// These tests drive the production seam end-to-end through the real
/// `Document` + `EditorCoordinator` (via `EditorIntegrationHarness`
/// .withRealDocument), then run the exact two lines `EditorSurface.updateNSView`
/// runs (consume the one-shot flag, `applyExternalText` when the buffer
/// differs). The undo action registered is a NON-text action (mirrors an
/// annotation/task op-undo registration) — the thing a remote merge should not
/// silently discard.
@MainActor
final class MergeUndoPreservationTests: XCTestCase {

    /// Reproduce `EditorSurface.updateNSView`'s undo-coherent apply seam: consume
    /// the Document's one-shot flag, and replace the buffer (preserving or
    /// clearing the stack per the flag) when it drifted from displayText.
    private func pumpEditorUpdate(_ rdh: RealDocumentHarness) {
        let flag = rdh.document.consumeUndoCoherentApplyFlag()
        let text = rdh.document.displayText
        if rdh.harness.textView.string != text {
            rdh.harness.coordinator.applyExternalText(
                text, preserveUndoStack: flag)
        }
    }

    /// Append a foreign op to the doc's op log under a peer device slug, then
    /// fire the presenter callback body (`handleExternalLogChange`).
    private func mergeForeignOp(
        _ op: Op, into rdh: RealDocumentHarness
    ) async throws {
        try await OpLogStore(projectURL: rdh.projectURL).append(op)
        try await rdh.document.handleExternalLogChange()
    }

    // MARK: - Test A — pure append preserves the stack (RED before the fix)

    func test_pureAppendMerge_preservesUndoStack() async throws {
        let rdh = try await EditorIntegrationHarness.withRealDocument(
            initialText: "Alpha.\n\nBeta.\n")
        let doc = rdh.document
        XCTAssertEqual(doc.sequence.count, 2, "fixture seeds two paragraphs")
        let p1 = doc.sequence[0], p2 = doc.sequence[1]

        // A non-text op-undo registration (annotation/task-op flavour) — the
        // stack a remote merge must not silently wipe.
        let um = UndoManager()
        rdh.harness.coordinator.undoManagerOverrideForTesting = um
        um.registerUndo(withTarget: self) { _ in }
        XCTAssertTrue(um.canUndo, "precondition: a registered undo action exists")

        // A peer APPENDS a brand-new paragraph at the end. No existing paragraph
        // is removed or rewritten → pure append. No local edit is pending, so
        // the merge's flush-first step does not fire; the merge is foreign-only.
        let p3 = ParagraphID.mint()
        let foreign = Op(
            opId: ULID.generate(),
            docId: doc.docId, at: Date(),
            device: "peer-mac", session: "peer-session",
            kind: .typingBurst,
            changes: [.init(paragraphId: p3, prior: nil, next: "Gamma.")],
            sequence: [p1, p2, p3], provenance: nil)
        try await mergeForeignOp(foreign, into: rdh)

        // The append merged in.
        XCTAssertEqual(doc.sequence, [p1, p2, p3],
            "the peer's appended paragraph joins the sequence")
        XCTAssertTrue(doc.displayText.contains("Gamma."),
            "the peer's new paragraph is in the published text")

        // Publish the merged state through the editor's update seam.
        pumpEditorUpdate(rdh)

        // The buffer was replaced (append changed displayText) but the ⌘Z stack
        // survived — a remote pure-append does not wipe the writer's undo.
        XCTAssertEqual(rdh.harness.textView.string, doc.displayText,
            "the append reached the editor buffer (a real replace occurred)")
        XCTAssertTrue(um.canUndo,
            "a pure-append peer merge must PRESERVE the ⌘Z stack (E3b) — fails today because the merge never arms _undoCoherentApplyPending, so applyExternalText(preserveUndoStack:false) calls removeAllActions")
    }

    // MARK: - Test B — editing an existing paragraph clears the stack (boundary)

    func test_editExistingParagraphMerge_clearsUndoStack() async throws {
        let rdh = try await EditorIntegrationHarness.withRealDocument(
            initialText: "Alpha.\n\nBeta.\n")
        let doc = rdh.document
        XCTAssertEqual(doc.sequence.count, 2, "fixture seeds two paragraphs")
        let p1 = doc.sequence[0], p2 = doc.sequence[1]

        let um = UndoManager()
        rdh.harness.coordinator.undoManagerOverrideForTesting = um
        um.registerUndo(withTarget: self) { _ in }
        XCTAssertTrue(um.canUndo, "precondition: a registered undo action exists")

        // A peer EDITS an existing paragraph's text — NOT a pure append. This is
        // the conservative boundary: the D1-consistent clear must stay, so a
        // preserved typing-undo entry can't pop against text that moved.
        let foreign = Op(
            opId: ULID.generate(),
            docId: doc.docId, at: Date(),
            device: "peer-mac", session: "peer-session",
            kind: .typingBurst,
            changes: [.init(paragraphId: p2,
                            prior: "Beta.", next: "Beta EDITED.")],
            sequence: [p1, p2], provenance: nil)
        try await mergeForeignOp(foreign, into: rdh)

        XCTAssertTrue(doc.displayText.contains("Beta EDITED."),
            "the peer's edit merged in")

        pumpEditorUpdate(rdh)

        XCTAssertEqual(rdh.harness.textView.string, doc.displayText,
            "the edit reached the editor buffer (a real replace occurred)")
        XCTAssertFalse(um.canUndo,
            "a merge that rewrites an existing paragraph must CLEAR the stale native undo stack (ADR 0023 D1 stays for non-pure-append) — passes today and after the fix, pinning the conservative boundary")
    }
}
