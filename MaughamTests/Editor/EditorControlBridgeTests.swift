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

    // MARK: - Fix 2 (Channel B): narrowed observation capture

    /// The control-plane observation must track ONLY `EditorControl` properties.
    /// Mutating a value that `applyControl` merely *reads through* while in review
    /// posture — e.g. `UserPreferences.collaboratorDisplayName`, read by the
    /// `reviewLocalAuthorName` provider inside `recomputeReviewMarks` — must NOT
    /// re-fire `applyControl` (which whole-doc restyles). Before the fix the
    /// initial `applyControl` ran INSIDE `withObservationTracking`, so those
    /// provider reads were tracked and any shared-prefs mutation re-fired the
    /// control plane in every review-mode window (ADR 0017 D1 exposure).
    func test_reviewObservation_ignoresSharedPreferencesMutation() async {
        let (coordinator, _) = makeCoordinator()
        let prefs = UserPreferences(defaults: UserDefaults(suiteName: "fix2-\(UUID().uuidString)")!)
        prefs.collaboratorDisplayName = "Before"
        // Provider read inside recomputeReviewMarks — the captured-before path.
        coordinator.reviewLocalAuthorName = { prefs.collaboratorDisplayName }

        let control = EditorControl()
        control.isReviewMode = true
        coordinator.observeControl(control)   // initial apply (review on)
        await settle()

        let baseline = coordinator.applyControlCount
        // Mutating the shared prefs must NOT re-fire the control plane.
        prefs.collaboratorDisplayName = "After"
        await settle()

        XCTAssertEqual(coordinator.applyControlCount, baseline,
            "a shared-prefs mutation must not re-fire applyControl (narrowed capture)")
    }

    /// The positive half: mutating an actual `EditorControl` property DOES
    /// re-apply — the observation is narrowed, not severed.
    func test_reviewObservation_stillFiresOnControlPropertyChange() async {
        let (coordinator, _) = makeCoordinator()
        let control = EditorControl()
        control.isReviewMode = true
        coordinator.observeControl(control)
        await settle()

        let baseline = coordinator.applyControlCount
        var bumped = TypographySettings.defaults
        bumped.fontSize = bumped.fontSize + 4
        control.typography = bumped
        await settle()

        XCTAssertGreaterThan(coordinator.applyControlCount, baseline,
            "an EditorControl property change must still re-apply the control plane")
    }

    /// The reference index's redraw trigger (plan 3b Task 1) is a
    /// control-plane input: a new version reaches the coordinator, and an
    /// unchanged one re-applies nothing new.
    func test_referenceIndexVersionReachesTheCoordinator() async {
        let (coordinator, _) = makeCoordinator()
        let control = EditorControl()
        coordinator.observeControl(control)
        XCTAssertEqual(coordinator.referenceIndexVersion, 0)

        control.referenceIndexVersion = 3
        await settle()
        XCTAssertEqual(coordinator.referenceIndexVersion, 3,
                       "the version must reach the coordinator through the model")
    }

    /// The figure cards' re-layout trigger (report plan 7a Task 4) is a
    /// control-plane input too: a new version re-applies and reaches the
    /// coordinator.
    func test_figureCardVersionReachesTheCoordinator() async {
        let (coordinator, _) = makeCoordinator()
        let control = EditorControl()
        coordinator.observeControl(control)
        await settle()
        XCTAssertEqual(coordinator.figureCardVersion, 0)
        let baseline = coordinator.applyControlCount

        control.figureCardVersion = 2
        await settle()
        XCTAssertGreaterThan(coordinator.applyControlCount, baseline,
                             "the version is in the tracked set")
        XCTAssertEqual(coordinator.figureCardVersion, 2,
                       "the version must reach the coordinator through the model")
    }

    /// The share's read-only flag and the window's explicit review mode
    /// (report plan 7c Task 8, the grid's gate) are control-plane inputs:
    /// each is in the tracked set, and a change reaches the coordinator.
    func test_theShareAndTheManualReviewModeReachTheCoordinator() async {
        let (coordinator, _) = makeCoordinator()
        let control = EditorControl()
        coordinator.observeControl(control)
        await settle()
        XCTAssertFalse(coordinator.shareIsReadOnly)
        XCTAssertFalse(coordinator.isManualReviewMode)

        var baseline = coordinator.applyControlCount
        control.shareIsReadOnly = true
        await settle()
        XCTAssertGreaterThan(coordinator.applyControlCount, baseline, "the share flag is in the tracked set")
        XCTAssertTrue(coordinator.shareIsReadOnly)

        baseline = coordinator.applyControlCount
        control.isManualReviewMode = true
        await settle()
        XCTAssertGreaterThan(coordinator.applyControlCount, baseline, "the manual review flag is in the tracked set")
        XCTAssertTrue(coordinator.isManualReviewMode)

        control.shareIsReadOnly = false
        control.isManualReviewMode = false
        await settle()
        XCTAssertFalse(coordinator.shareIsReadOnly)
        XCTAssertFalse(coordinator.isManualReviewMode)
    }
}
