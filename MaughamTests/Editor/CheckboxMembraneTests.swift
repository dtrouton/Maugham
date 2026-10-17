import XCTest
import SwiftUI
import AppKit
import MaughamCore
@testable import Maugham

/// A checkbox click writes text, so it asks the same membrane a keystroke does
/// (#74). Pinned windowlessly (tripwire 33): the decision, not a synthesised click.
final class CheckboxMembraneTests: XCTestCase {
    func test_aLockedEditorRefusesACheckboxToggle() {
        XCTAssertFalse(EditorEditPolicy.allowsCheckboxToggle(
            lockEditing: true, isTranslationReview: false))
    }

    func test_theTranslationViewRefusesACheckboxToggle() {
        XCTAssertFalse(EditorEditPolicy.allowsCheckboxToggle(
            lockEditing: false, isTranslationReview: true))
    }

    func test_anUnlockedEditorAllowsACheckboxToggle() {
        XCTAssertTrue(EditorEditPolicy.allowsCheckboxToggle(
            lockEditing: false, isTranslationReview: false))
    }

    @MainActor
    func test_theCoordinatorAsksItsOwnMembraneForACheckbox() {
        final class TextBox { var value = "- [ ] task" }
        let box = TextBox()
        let coordinator = EditorCoordinator(
            text: Binding(get: { box.value }, set: { box.value = $0 }),
            mode: ProseMode(),
            theme: .light, typography: .defaults,
            typewriterScroll: false,
            sentenceFocus: false, paragraphFocus: false)
        XCTAssertTrue(coordinator.allowsCheckboxToggle)
        coordinator.setLockEditing(true)
        XCTAssertFalse(coordinator.allowsCheckboxToggle)
        coordinator.setLockEditing(false)
        coordinator.setTranslationReview(true)
        XCTAssertFalse(coordinator.allowsCheckboxToggle)
        coordinator.setTranslationReview(false)
        XCTAssertTrue(coordinator.allowsCheckboxToggle)
    }
}
