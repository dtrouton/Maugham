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
final class TranslationReviewPostureTests: XCTestCase {

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
                            isTranslationReview: translation),
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
            isReviewMode: false, lockEditing: false, isTranslationReview: true))
        XCTAssertTrue(EditorEditPolicy.allowsTextMutation(
            isReviewMode: false, lockEditing: false, isTranslationReview: false))
    }

    // MARK: - Coordinator membrane (synchronous flip)

    /// `setTranslationReview(true)` must block the very next keystroke through the
    /// single `shouldChangeTextIn` choke point — no SwiftUI render round-trip —
    /// mirroring the `setReviewMode`/`setLockEditing` synchronous-flip contract.
    @MainActor
    func test_setTranslationReview_blocksMutationImmediately() {
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

        coordinator.setTranslationReview(true)
        XCTAssertFalse(
            coordinator.textView(tv, shouldChangeTextIn: NSRange(location: 5, length: 0),
                                 replacementString: "x"),
            "translation review must block the very next keystroke")

        coordinator.setTranslationReview(false)
        XCTAssertTrue(
            coordinator.textView(tv, shouldChangeTextIn: NSRange(location: 5, length: 0),
                                 replacementString: "x"),
            "leaving translation review must restore normal editing")
    }

    // MARK: - Harness: end-to-end read-only posture (zero ops)

    /// Enter translation review on a real Document → simulated typing mutates
    /// NOTHING: op-log length unchanged, `displayText` unchanged, the text view's
    /// buffer unchanged, and `applyExternalText` never fires around the typing.
    /// Exiting the posture restores normal editing.
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
        harness.coordinator.setTranslationReview(true)

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
        harness.coordinator.setTranslationReview(false)
        harness.typeCharacter("Q")
        XCTAssertNotEqual(doc.displayText, displayBefore,
            "leaving translation review must restore normal editing")

        await doc.close()
    }
}
