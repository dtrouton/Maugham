import XCTest
import SwiftUI
import AppKit
import MaughamCore
@testable import Maugham

/// Task 11: the read-only translation-review posture. Entering translation
/// review makes the editor membrane reject every manuscript mutation (the same
/// single `shouldChangeTextIn` choke point that enforces review-mode and the
/// role lock), so the translated surface a reader is inspecting can never be
/// edited by accident and produces ZERO ops.
final class ReadingTranslationPostureTests: XCTestCase {

    // MARK: - Policy (all 8 flag combinations)

    /// `allowsTextMutation` returns true ONLY when all three blocking reasons are
    /// false. Any one of review-mode, the role lock, or translation-review blocks
    /// mutation. Exhaustive over the 2^3 truth table.
    func test_allowsTextMutation_truthTable() {
        for review in [false, true] {
            for lock in [false, true] {
                for translation in [false, true] {
                    let expected = !review && !lock && !translation
                    XCTAssertEqual(
                        EditorEditPolicy.allowsTextMutation(
                            isReviewMode: review,
                            lockEditing: lock,
                            isReadingTranslation: translation),
                        expected,
                        "review=\(review) lock=\(lock) translation=\(translation) "
                        + "should allow=\(expected)")
                }
            }
        }
    }

    /// Translation review alone (no manual review render, no role lock) must block
    /// mutation — it is an independent third reason.
    func test_translationReviewAlone_blocksMutation() {
        XCTAssertFalse(EditorEditPolicy.allowsTextMutation(
            isReviewMode: false, lockEditing: false, isReadingTranslation: true))
        XCTAssertTrue(EditorEditPolicy.allowsTextMutation(
            isReviewMode: false, lockEditing: false, isReadingTranslation: false))
    }

    // MARK: - Coordinator membrane (synchronous flip)

    /// `setReadingTranslation(true)` must block the very next keystroke through the
    /// single `shouldChangeTextIn` choke point — no SwiftUI render round-trip —
    /// mirroring the `setReviewMode`/`setLockEditing` synchronous-flip contract.
    @MainActor
    func test_setReadingTranslation_blocksMutationImmediately() {
        final class TextBox { var value = "Hello world" }
        let box = TextBox()
        let coordinator = EditorCoordinator(
            text: Binding(get: { box.value }, set: { box.value = $0 }),
            mode: ProseMode(),
            theme: .light, typography: .defaults,
            typewriterScroll: false,
            sentenceFocus: false, paragraphFocus: false)
        let tv = NSTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        tv.string = box.value
        tv.delegate = coordinator
        coordinator.attach(to: tv)

        XCTAssertTrue(
            coordinator.textView(tv, shouldChangeTextIn: NSRange(location: 5, length: 0),
                                 replacementString: "x"),
            "edits must pass before translation review is on")

        coordinator.setReadingTranslation(true)
        XCTAssertFalse(
            coordinator.textView(tv, shouldChangeTextIn: NSRange(location: 5, length: 0),
                                 replacementString: "x"),
            "translation review must block the very next keystroke")

        coordinator.setReadingTranslation(false)
        XCTAssertTrue(
            coordinator.textView(tv, shouldChangeTextIn: NSRange(location: 5, length: 0),
                                 replacementString: "x"),
            "leaving translation review must restore normal editing")
    }

    // MARK: - Harness: end-to-end read-only posture (zero ops)

    /// Drives the coordinator membrane setter DIRECTLY (`setReadingTranslation`),
    /// i.e. the membrane in isolation — NOT the control-model/`updateNSView` entry
    /// path (that end-to-end race is covered by
    /// `test_enteringTranslationReview_*` / `test_exitingTranslationReview_*`
    /// below, which hand-pump `EditorSurface.reconcileTextBuffer`). With the
    /// membrane on, simulated typing on a real Document mutates NOTHING: op-log
    /// length unchanged, `displayText` unchanged, the text-view buffer unchanged,
    /// and `applyExternalText` never fires around the typing. Exiting restores
    /// normal editing.
    @MainActor
    func test_translationReview_typingProducesZeroOps_thenExitRestoresEditing() async throws {
        let rd = try await EditorIntegrationHarness.withRealDocument(
            mode: ProseMode(),
            initialText: "Hello world\n\nSecond paragraph")
        let harness = rd.harness
        let doc = rd.document

        let opCountBefore = doc.opLogMirrorCount
        let displayBefore = doc.displayText
        let bufferBefore = harness.currentText

        // Enter the read-only translation-review posture.
        harness.coordinator.setReadingTranslation(true)

        // Typing is fully blocked at the membrane, so no buffer replace can be
        // needed — assert applyExternalText never fires AROUND the typing itself.
        harness.assertNoApplyExternalText {
            harness.typeCharacter("X")
            harness.typeCharacter("Y")
            harness.typeCharacter("Z")
        }

        // Force any (non-existent) burst to flush so a stray op would surface.
        try await doc.flushBurstNow()

        XCTAssertEqual(doc.opLogMirrorCount, opCountBefore,
            "translation review must produce ZERO ops from typing")
        XCTAssertEqual(doc.displayText, displayBefore,
            "translation review must leave displayText unchanged")
        XCTAssertEqual(harness.currentText, bufferBefore,
            "translation review must leave the text-view buffer unchanged")

        // Exit the posture — editing works again.
        harness.coordinator.setReadingTranslation(false)
        harness.typeCharacter("Q")
        XCTAssertNotEqual(doc.displayText, displayBefore,
            "leaving translation review must restore normal editing")

        await doc.close()
    }

    // MARK: - Entry/exit race (real control-plane wiring, hand-pumped updateNSView)

    /// The Critical race: `control.translationLanguage` changing drives TWO
    /// independent reactions with no ordering guarantee — the coordinator's async
    /// observation re-arm (flips the membrane on a LATER main-actor turn) vs
    /// SwiftUI's render → `updateNSView` → buffer swap. If the render wins, the
    /// translated text is briefly EDITABLE and a keystroke lands in the op log.
    ///
    /// This drives the REAL entry point (mutating the observed `EditorControl`,
    /// NOT `setReadingTranslation` directly) and then hand-pumps
    /// `EditorSurface.reconcileTextBuffer` — the exact reconciliation
    /// `updateNSView` performs — WITHOUT settling first, so the render deliberately
    /// wins the race against the not-yet-run async re-arm. The synchronous membrane
    /// flip inside `reconcileTextBuffer` is what makes the keystroke-in-the-window
    /// assertion pass: strip that flip and the membrane is still off here (the
    /// async re-arm hasn't run), the keystroke lands, and this fails.
    ///
    /// `NSViewRepresentable.Context` is unsynthesizable, so the SwiftUI
    /// body-eval → `updateNSView` dispatch itself remains machine-unverifiable
    /// (smoke-only); everything from the reconciliation onward is exercised here.
    @MainActor
    func test_enteringTranslationReview_membraneFlipsBeforeBufferSwap_typingNeverLands() async throws {
        let rd = try await EditorIntegrationHarness.withRealDocument(
            mode: ProseMode(),
            initialText: "Source one\n\nSource two")
        let harness = rd.harness
        let doc = rd.document
        let coordinator = harness.coordinator

        // Wire the REAL control-plane model — the production entry point. Initial
        // apply runs with language nil, so the membrane starts off.
        let control = EditorControl()
        coordinator.observeControl(control)
        XCTAssertFalse(coordinator.isReadingTranslation)

        let opCountBefore = doc.opLogMirrorCount
        let displayBefore = doc.displayText
        let translated = "Traduction un\n\nTraduction deux"

        // Enter translation review through the REAL entry point. This schedules
        // the async observation re-arm; it does NOT flip the membrane yet.
        control.translationLanguage = "fr"

        // Simulate the render that carries the translated surface into the buffer
        // (EditorHost sets translatedSurfaceText → updateNSView) — WITHOUT
        // settling, so this wins the race against the async re-arm.
        EditorSurface.reconcileTextBuffer(
            textView: harness.textView,
            coordinator: coordinator,
            translationLanguage: control.translationLanguage,
            text: translated,
            undoCoherentApply: false)

        XCTAssertEqual(harness.currentText, translated,
            "the translated surface must be swapped into the buffer")
        // The membrane is ALREADY blocking here — before the async re-arm ran.
        // A keystroke in this window must not land.
        harness.assertNoApplyExternalText {
            harness.typeCharacter("X")
        }
        try await doc.flushBurstNow()

        XCTAssertEqual(doc.opLogMirrorCount, opCountBefore,
            "a keystroke during the entry transition must produce ZERO ops")
        XCTAssertEqual(doc.displayText, displayBefore,
            "the source manuscript must be untouched by the blocked keystroke")
        XCTAssertEqual(harness.currentText, translated,
            "the buffer must still show translated text (keystroke blocked)")

        await doc.close()
    }

    /// Symmetric exit: leaving translation review (`translationLanguage → nil`)
    /// must release the membrane synchronously in the same pass the source buffer
    /// is swapped back in, so editing resumes IMMEDIATELY — without waiting for the
    /// async re-arm. Strip the synchronous flip and the membrane is still on here
    /// (async re-arm not yet run), the keystroke is blocked, and this fails.
    @MainActor
    func test_exitingTranslationReview_membraneFlipsBeforeBufferSwap_editingResumes() async throws {
        let rd = try await EditorIntegrationHarness.withRealDocument(
            mode: ProseMode(),
            initialText: "Source one\n\nSource two")
        let harness = rd.harness
        let doc = rd.document
        let coordinator = harness.coordinator

        // Start IN translation review: initial apply flips the membrane on.
        let control = EditorControl()
        control.translationLanguage = "fr"
        coordinator.observeControl(control)
        XCTAssertTrue(coordinator.isReadingTranslation,
            "initial apply with a language must enter translation review")

        // Model the entered state: translated text sits in the buffer.
        let translated = "Traduction un\n\nTraduction deux"
        EditorSurface.reconcileTextBuffer(
            textView: harness.textView,
            coordinator: coordinator,
            translationLanguage: "fr",
            text: translated,
            undoCoherentApply: false)
        XCTAssertEqual(harness.currentText, translated)

        // Exit through the REAL entry point (schedules the async re-arm)…
        control.translationLanguage = nil
        // …then hand-pump the render that swaps the source surface back in, WITHOUT
        // settling — the render wins the race against the async re-arm.
        EditorSurface.reconcileTextBuffer(
            textView: harness.textView,
            coordinator: coordinator,
            translationLanguage: control.translationLanguage,
            text: doc.displayText,
            undoCoherentApply: false)

        XCTAssertEqual(harness.currentText, doc.displayText,
            "the source manuscript must be restored to the buffer on exit")
        XCTAssertFalse(coordinator.isReadingTranslation,
            "the membrane must be released synchronously on exit")

        // Editing resumes right away — no settle for the async re-arm.
        let opCountBefore = doc.opLogMirrorCount
        harness.typeCharacter("Q")
        try await doc.flushBurstNow()
        XCTAssertGreaterThan(doc.opLogMirrorCount, opCountBefore,
            "editing must resume immediately after exiting translation review")

        await doc.close()
    }

    // MARK: - The window's undo across a translation (shell p4 Task 8 fix I5)

    /// **Reading a translation never touches the window's stack, and ⌘Z there
    /// cannot reach it** (controller's ruling I5, replacing Task 11's "the
    /// entry swap clears the stack"): the view's undo manager is a throwaway
    /// while the buffer holds a translation, and the swap's clear is that
    /// throwaway's. The D1 crash class stays closed — the native typing
    /// actions on the window's stack are never popped against a surface they
    /// do not describe — and is closed again on the way out
    /// (`test_leavingToAChangedSourceDropsTheStack`).
    @MainActor
    func test_enteringAndRefreshingATranslationKeepTheWindowsStackOutOfReach() {
        let harness = EditorIntegrationHarness(initialText: "Source one")
        let coordinator = harness.coordinator
        let um = UndoManager()
        coordinator.undoManagerOverrideForTesting = um
        um.registerUndo(withTarget: self) { _ in }   // the writer's history
        EditorSurface.reconcileTextBuffer(
            textView: harness.textView, coordinator: coordinator,
            translationLanguage: "fr", text: "Traduction un", undoCoherentApply: true)
        XCTAssertTrue(coordinator.isReadingTranslation)
        XCTAssertTrue(um.canUndo, "the writer's history survives the swap in")
        XCTAssertTrue(harness.textView.undoManager === coordinator.readingUndoManager,
                      "⌘Z over the translation reaches the throwaway, never the writer's history")
        EditorSurface.reconcileTextBuffer(
            textView: harness.textView, coordinator: coordinator,
            translationLanguage: "fr", text: "Traduction deux", undoCoherentApply: true)
        XCTAssertTrue(um.canUndo, "an in-mode refresh keeps it too")
        XCTAssertFalse(coordinator.readingUndoManager.canUndo)
    }

    /// Leaving to the very source the stack was built on keeps it; leaving to a
    /// source that changed meanwhile (a merge, an op undone) drops it — its
    /// typing ranges are stale (ADR 0023 D1).
    @MainActor
    func test_leavingToTheSameSourceKeepsTheStack() {
        let harness = EditorIntegrationHarness(initialText: "Source one")
        let coordinator = harness.coordinator
        let um = UndoManager()
        coordinator.undoManagerOverrideForTesting = um
        um.registerUndo(withTarget: self) { _ in }
        EditorSurface.reconcileTextBuffer(
            textView: harness.textView, coordinator: coordinator,
            translationLanguage: "fr", text: "Traduction un", undoCoherentApply: false)
        EditorSurface.reconcileTextBuffer(
            textView: harness.textView, coordinator: coordinator,
            translationLanguage: nil, text: "Source one", undoCoherentApply: false)
        XCTAssertFalse(coordinator.isReadingTranslation)
        XCTAssertTrue(um.canUndo)
        XCTAssertFalse(harness.textView.undoManager === coordinator.readingUndoManager)
    }

    @MainActor
    func test_leavingToAChangedSourceDropsTheStack() {
        let harness = EditorIntegrationHarness(initialText: "Source one")
        let coordinator = harness.coordinator
        let um = UndoManager()
        coordinator.undoManagerOverrideForTesting = um
        um.registerUndo(withTarget: self) { _ in }
        EditorSurface.reconcileTextBuffer(
            textView: harness.textView, coordinator: coordinator,
            translationLanguage: "fr", text: "Traduction un", undoCoherentApply: false)
        EditorSurface.reconcileTextBuffer(
            textView: harness.textView, coordinator: coordinator,
            translationLanguage: nil, text: "Source one, merged", undoCoherentApply: false)
        XCTAssertFalse(um.canUndo, "a changed source makes the typing ranges stale (D1)")
    }

    /// **Type, read in a language, come back, ⌘Z: the typing is undone** — the
    /// writer's own words through the real window undo manager (fix I5).
    @MainActor
    func test_typeSwitchLanguageSwitchBackAndUndoRestores() {
        let harness = EditorIntegrationHarness(initialText: "One two")
        let tv = harness.textView
        let coordinator = harness.coordinator
        let um = tv.undoManager!
        um.groupsByEvent = false
        um.beginUndoGrouping()
        tv.setSelectedRange(NSRange(location: 7, length: 0))
        tv.insertText(" three", replacementRange: NSRange(location: NSNotFound, length: 0))
        um.endUndoGrouping()
        XCTAssertEqual(tv.string, "One two three")
        EditorSurface.reconcileTextBuffer(textView: tv, coordinator: coordinator,
                                          translationLanguage: "sr", text: "Jedan dva tri",
                                          undoCoherentApply: false)
        // ⌘Z over the translation spends nothing.
        tv.undoManager?.undo()
        XCTAssertEqual(tv.string, "Jedan dva tri")
        EditorSurface.reconcileTextBuffer(textView: tv, coordinator: coordinator,
                                          translationLanguage: nil, text: "One two three",
                                          undoCoherentApply: false)
        XCTAssertTrue(um.canUndo, "the writer's typing is still there to undo")
        tv.undoManager?.undo()
        XCTAssertEqual(tv.string, "One two", "and ⌘Z takes it back")
    }

    /// Control half: when the membrane does NOT change this pass (an ordinary
    /// accept/revert replace, no translation transition), the one-shot
    /// undo-coherent flag is honored and the accept-registered undo action survives.
    @MainActor
    func test_reconcile_nonTranslationSwap_honorsUndoCoherentFlag() {
        let harness = EditorIntegrationHarness(initialText: "Source one")
        let coordinator = harness.coordinator
        let um = UndoManager()
        coordinator.undoManagerOverrideForTesting = um
        um.registerUndo(withTarget: self) { _ in }   // accept/revert registration
        XCTAssertTrue(um.canUndo)

        // No translation transition (language stays nil → membrane unchanged); the
        // undo-coherent flag must be honored so the accept registration survives.
        EditorSurface.reconcileTextBuffer(
            textView: harness.textView,
            coordinator: coordinator,
            translationLanguage: nil,
            text: "Accepted revision",
            undoCoherentApply: true)

        XCTAssertFalse(coordinator.isReadingTranslation)
        XCTAssertTrue(um.canUndo,
            "a non-translation undo-coherent replace must keep the accept-undo "
            + "registration")
    }
}
