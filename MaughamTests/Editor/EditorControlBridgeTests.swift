import XCTest
import SwiftUI
import AppKit
import MaughamCore
@testable import Maugham

@MainActor
final class EditorControlBridgeTests: XCTestCase {

    private func makeCoordinator() -> (EditorCoordinator, NSTextView) {
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
        return (coordinator, tv)
    }

    /// Wait briefly for the re-arming observation Task to apply.
    private func settle() async {
        try? await Task.sleep(for: .milliseconds(50))
    }

    /// The model drives the membrane: initial apply locks; a later change unlocks
    /// in place (no key window, no notification, no view rebuild).
    func test_controlModel_drivesMembraneOnChange() async {
        let (coordinator, _) = makeCoordinator()
        let control = EditorControl()
        control.lockEditing = true
        control.isReviewMode = true

        coordinator.observeControl(control)   // initial apply
        XCTAssertTrue(coordinator.lockEditing, "initial apply must lock")
        XCTAssertTrue(coordinator.isReviewMode)

        // Resolve to author.
        control.lockEditing = false
        control.isReviewMode = false
        await settle()

        XCTAssertFalse(coordinator.lockEditing, "model change must unlock in place")
        XCTAssertFalse(coordinator.isReviewMode)
    }

    /// Appearance flows through the model too, guarded (D2): a typography change
    /// lands on the coordinator.
    func test_controlModel_drivesAppearance() async {
        let (coordinator, _) = makeCoordinator()
        let control = EditorControl()
        control.theme = .light
        control.typography = .defaults
        coordinator.observeControl(control)

        var bumped = TypographySettings.defaults
        bumped.fontSize = bumped.fontSize + 3
        control.typography = bumped
        await settle()

        XCTAssertEqual(coordinator.typography.fontSize, bumped.fontSize,
            "typography change must reach the coordinator via the model")
    }
}
