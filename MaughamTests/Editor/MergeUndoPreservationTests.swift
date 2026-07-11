import XCTest
import AppKit
import MaughamCore
@testable import Maugham

/// Task 7 — E3(b), conservative slice: a peer op-log merge must preserve the
/// writer's ⌘Z stack ONLY when it is safe to do so, and keep the D1-consistent
/// clear otherwise (ADR 0023 §2).
///
/// `Document.handleExternalLogChange` publishes merged state via
/// `recomputeDisplayText` → the editor's next update pass →
/// `applyExternalText(preserveUndoStack:)`. Every buffer replace does a
/// wholesale `textView.string = …` and clears the native typing-undo stack (the
/// v0.16.0 ⌘Z EXC_BAD_ACCESS class) UNLESS the Document armed
/// `_undoCoherentApplyPending`. Before this fix the merge never armed it, so a
/// remote peer's op — even one appending a new paragraph elsewhere — wiped the
/// whole stack.
///
/// The safe-to-preserve condition is a RANGE-SAFETY invariant: a preserved
/// native typing-undo action holds absolute character ranges, so it stays valid
/// only if the new display text has the old display text as a literal prefix
/// (an end-of-document append). A reorder or a mid-sequence insert shifts
/// offsets after the change point and must clear the stack — a preserved action
/// would otherwise pop against text that moved (the stale-range crash).
///
/// These tests drive the production seam end-to-end through the real
/// `Document` + `EditorCoordinator` (via `EditorIntegrationHarness`
/// .withRealDocument), then replay the exact two lines
/// `EditorSurface.updateNSView` runs (`pumpEditorUpdate`).
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

    /// Make the loaded document's op-log mirror durable on disk.
    ///
    /// `withRealDocument` bootstraps the doc in memory but no autosave runs in
    /// the offscreen harness, so the bootstrap op stays in `_opLogMirror` and
    /// never reaches disk. `handleExternalLogChange` re-derives from DISK, so
    /// without this the merge would lose every un-edited original paragraph
    /// (they stay in `sequence` but have no text, and `recomputeDisplayText`
    /// skips them). In production the bootstrap append is always on disk
    /// (`emitBootstrap`), so this just recreates that precondition.
    private func persistMirror(_ rdh: RealDocumentHarness) async throws {
        let store = OpLogStore(projectURL: rdh.projectURL)
        for op in rdh.document._opLogMirror {
            try await store.append(op)
        }
    }

    // MARK: - Test C — end-append preserves a REAL range-based typing undo (teeth)

    /// The preserve case, proven SAFE rather than merely armed: a genuine
    /// range-based typing-undo action (mutates the buffer on fire, as
    /// NSTextView's own typing undo does) survives a pure end-append merge AND
    /// fires correctly afterward — its captured range is still valid because the
    /// append left every prior offset unmoved.
    func test_endAppendMerge_preservesAndSafelyFiresRangeBasedTypingUndo() async throws {
        let rdh = try await EditorIntegrationHarness.withRealDocument(
            initialText: "Alpha.\n\nBeta.")
        let doc = rdh.document
        let tv = rdh.harness.textView
        XCTAssertEqual(doc.sequence.count, 2, "fixture seeds two paragraphs")
        try await persistMirror(rdh)

        // A real edit driven through the coordinator: type "Z" at the end of the
        // last paragraph. This mutates the Document (via the binding setter) and
        // the editor buffer, exactly as a keystroke does.
        rdh.harness.setCursor(to: (tv.string as NSString).length)
        await rdh.harness.typeString("Z")
        XCTAssertEqual(tv.string, "Alpha.\n\nBeta.Z",
            "the keystroke reached the buffer")
        XCTAssertEqual(doc.displayText, "Alpha.\n\nBeta.Z",
            "the keystroke reached the Document")

        // Commit the local burst so the upcoming merge is a clean foreign append
        // (no flush-first op competing for the newest sequence).
        try await doc.flushBurstNow()
        let p1 = doc.sequence[0], p2 = doc.sequence[1]

        // Register a REAL range-based undo action — the kind NSTextView's typing
        // undo registers — on the coordinator's undo manager (nil in the offscreen
        // harness, hence the override seam). On fire it deletes the typed "Z" via
        // its CAPTURED range; a stale range would crash or corrupt, so firing it
        // is a genuine safety assertion, not a no-op.
        let um = UndoManager()
        rdh.harness.coordinator.undoManagerOverrideForTesting = um
        let zLocation = (tv.string as NSString).length - 1
        um.registerUndo(withTarget: tv) { target in
            target.textStorage?.replaceCharacters(
                in: NSRange(location: zLocation, length: 1), with: "")
        }
        XCTAssertTrue(um.canUndo, "precondition: a range-based typing undo exists")

        // A peer APPENDS a new paragraph at the very end — the only range-safe
        // shape (new displayText has the old as a literal prefix).
        let p3 = ParagraphID.mint()
        let foreign = Op(
            opId: ULID.generate(),
            docId: doc.docId, at: Date(),
            device: "peer-mac", session: "peer-session",
            kind: .typingBurst,
            changes: [.init(paragraphId: p3, prior: nil, next: "Gamma.")],
            sequence: [p1, p2, p3], provenance: nil)
        try await mergeForeignOp(foreign, into: rdh)

        XCTAssertEqual(doc.displayText, "Alpha.\n\nBeta.Z\n\nGamma.",
            "the append lands at the end (old displayText is a literal prefix)")

        pumpEditorUpdate(rdh)

        XCTAssertEqual(tv.string, doc.displayText,
            "the append reached the editor buffer (a real replace occurred)")
        XCTAssertTrue(um.canUndo,
            "a pure end-append preserves the range-based typing undo (E3b)")

        // Teeth: fire the preserved action. Its captured range is still valid, so
        // it deletes the typed "Z" cleanly and leaves the appended paragraph
        // intact — no stale-range crash/corruption.
        um.undo()
        XCTAssertFalse(tv.string.contains("Beta.Z"),
            "firing the preserved typing undo removed the typed char — its range stayed valid across the append")
        XCTAssertTrue(tv.string.contains("Beta."),
            "the paragraph survives with the Z undone")
        XCTAssertTrue(tv.string.contains("Gamma."),
            "the appended paragraph is untouched by the typing-undo")
    }

    // MARK: - Test A — reorder of existing paragraphs clears the stack (RED before fix)

    func test_reorderMerge_clearsUndoStack() async throws {
        let rdh = try await EditorIntegrationHarness.withRealDocument(
            initialText: "One.\n\nTwo.\n\nThree.")
        let doc = rdh.document
        XCTAssertEqual(doc.sequence.count, 3, "fixture seeds three paragraphs")
        try await persistMirror(rdh)
        let p1 = doc.sequence[0], p2 = doc.sequence[1], p3 = doc.sequence[2]

        let um = UndoManager()
        rdh.harness.coordinator.undoManagerOverrideForTesting = um
        um.registerUndo(withTarget: self) { _ in }
        XCTAssertTrue(um.canUndo, "precondition: a registered undo action exists")

        // A peer REORDERS the existing paragraphs (empty changes, new sequence).
        // No paragraph text changed and none was removed, so the OLD paragraph-map
        // predicate wrongly classed this pure-append; the displayText-prefix
        // predicate correctly rejects it (offsets moved).
        let foreign = Op(
            opId: ULID.generate(),
            docId: doc.docId, at: Date(),
            device: "peer-mac", session: "peer-session",
            kind: .typingBurst,
            changes: [], sequence: [p3, p1, p2], provenance: nil)
        try await mergeForeignOp(foreign, into: rdh)

        XCTAssertEqual(doc.sequence, [p3, p1, p2], "the peer's reorder merged in")
        XCTAssertTrue(doc.displayText.hasPrefix("Three."),
            "the reordered text no longer has the old text as a prefix")

        pumpEditorUpdate(rdh)

        XCTAssertEqual(rdh.harness.textView.string, doc.displayText,
            "the reorder reached the editor buffer (a real replace occurred)")
        XCTAssertFalse(um.canUndo,
            "a reorder shifts character offsets — the stale native undo stack must be CLEARED (RED against the old paragraph-map predicate, which preserved it)")
    }

    // MARK: - Test B — mid-sequence insert clears the stack (RED before fix)

    func test_midSequenceInsertMerge_clearsUndoStack() async throws {
        let rdh = try await EditorIntegrationHarness.withRealDocument(
            initialText: "One.\n\nThree.")
        let doc = rdh.document
        XCTAssertEqual(doc.sequence.count, 2, "fixture seeds two paragraphs")
        try await persistMirror(rdh)
        let pA = doc.sequence[0], pB = doc.sequence[1]

        let um = UndoManager()
        rdh.harness.coordinator.undoManagerOverrideForTesting = um
        um.registerUndo(withTarget: self) { _ in }
        XCTAssertTrue(um.canUndo, "precondition: a registered undo action exists")

        // A peer INSERTS a new paragraph BETWEEN the two existing ones. No
        // existing paragraph's text changed and none was removed — the old
        // paragraph-map predicate classed this pure-append — but the insert
        // shifts every offset after it, so a preserved typing-undo would go stale.
        let pM = ParagraphID.mint()
        let foreign = Op(
            opId: ULID.generate(),
            docId: doc.docId, at: Date(),
            device: "peer-mac", session: "peer-session",
            kind: .typingBurst,
            changes: [.init(paragraphId: pM, prior: nil, next: "Two.")],
            sequence: [pA, pM, pB], provenance: nil)
        try await mergeForeignOp(foreign, into: rdh)

        XCTAssertEqual(doc.displayText, "One.\n\nTwo.\n\nThree.",
            "the peer's paragraph inserted in the middle")
        XCTAssertFalse(doc.displayText.hasPrefix("One.\n\nThree."),
            "a mid-insert breaks the old-text-is-a-prefix invariant")

        pumpEditorUpdate(rdh)

        XCTAssertEqual(rdh.harness.textView.string, doc.displayText,
            "the insert reached the editor buffer (a real replace occurred)")
        XCTAssertFalse(um.canUndo,
            "a mid-sequence insert shifts character offsets — the stale native undo stack must be CLEARED (RED against the old paragraph-map predicate, which preserved it)")
    }

    // MARK: - Test D — editing an existing paragraph clears the stack (boundary)

    func test_editExistingParagraphMerge_clearsUndoStack() async throws {
        let rdh = try await EditorIntegrationHarness.withRealDocument(
            initialText: "Alpha.\n\nBeta.")
        let doc = rdh.document
        XCTAssertEqual(doc.sequence.count, 2, "fixture seeds two paragraphs")
        try await persistMirror(rdh)
        let p1 = doc.sequence[0], p2 = doc.sequence[1]

        let um = UndoManager()
        rdh.harness.coordinator.undoManagerOverrideForTesting = um
        um.registerUndo(withTarget: self) { _ in }
        XCTAssertTrue(um.canUndo, "precondition: a registered undo action exists")

        // A peer REWRITES an existing paragraph's text — not range-safe.
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
            "a merge that rewrites an existing paragraph must CLEAR the stale native undo stack (ADR 0023 D1 stays for non-pure-append)")
    }
}
