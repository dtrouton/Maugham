// MaughamTests/Editor/EditorUndoStackClearTests.swift
import XCTest
import AppKit
@testable import Maugham

/// Regression net for the ⌘Z EXC_BAD_ACCESS crash (crash log
/// Maugham-2026-07-08-184105.ips, v0.16.0): replacing the NSTextView buffer
/// out from under AppKit invalidates every native typing-undo action, and a
/// subsequent ⌘Z segfaults in `_NSUndoStack popAndInvoke`. `applyExternalText`
/// must drop the stale native undo stack on every real replace — UNLESS the
/// apply was flagged undo-coherent (accept/revert registered its own action).
@MainActor
final class EditorUndoStackClearTests: XCTestCase {

    /// Builds a coordinator + text view via the shared harness setup.
    private func makeHarness(initialText: String = "original")
        -> EditorIntegrationHarness
    {
        EditorIntegrationHarness(initialText: initialText)
    }

    func test_applyExternalText_clearsStaleUndoStack() {
        let harness = makeHarness()
        let coordinator = harness.coordinator
        let um = UndoManager()
        coordinator.undoManagerOverrideForTesting = um
        um.registerUndo(withTarget: self) { _ in }   // simulate stale typing action
        XCTAssertTrue(um.canUndo)
        coordinator.applyExternalText("replaced buffer contents")
        XCTAssertFalse(um.canUndo,
            "external replace must drop the stale native undo stack (⌘Z segfault class)")
    }

    func test_applyExternalText_preserveUndoStack_keepsRegistrations() {
        let harness = makeHarness()
        let coordinator = harness.coordinator
        let um = UndoManager()
        coordinator.undoManagerOverrideForTesting = um
        um.registerUndo(withTarget: self) { _ in }   // simulate accept-revert registration
        coordinator.applyExternalText("replaced buffer contents", preserveUndoStack: true)
        XCTAssertTrue(um.canUndo,
            "undo-coherent apply must not wipe the accept-undo registration")
    }

    func test_applyExternalText_noBufferChange_touchesNothing() {
        let harness = makeHarness()
        let coordinator = harness.coordinator
        let textView = harness.textView
        let um = UndoManager()
        coordinator.undoManagerOverrideForTesting = um
        um.registerUndo(withTarget: self) { _ in }
        coordinator.applyExternalText(textView.string)  // same text — early return
        XCTAssertTrue(um.canUndo)
    }
}
