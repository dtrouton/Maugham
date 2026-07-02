import XCTest
import SwiftUI
import AppKit
import MaughamCore
@testable import Maugham

/// Regression net for the appearance-change plumbing (fix/oplog-spine-hardening).
///
/// Before the fix `MaughamTextView.viewDidChangeEffectiveAppearance` posted a
/// NotificationCenter *broadcast* (`.maughamEffectiveAppearanceChanged`,
/// `object: nil`). AppKit calls `viewDidChangeEffectiveAppearance` on FIRST
/// mount of every view (i.e. on every piece flip, since each flip builds a new
/// `EditorSurface`), not only on an OS light/dark change — so a per-mount
/// broadcast fanned a full whole-doc restyle out to EVERY live coordinator,
/// including ones belonging to closed windows whose graph SwiftUI had not yet
/// released. On a 174KB screenplay that restyle is ~seconds of work.
///
/// The fix makes the appearance change a DIRECT per-view call
/// (`coordinator.effectiveAppearanceDidChange()`) and no-ops when the effective
/// appearance name is unchanged since the last handled change.
@MainActor
final class EditorAppearanceChangeTests: XCTestCase {

    private func makeMaughamTextView(_ text: String = "Hello world") -> MaughamTextView {
        let tv = MaughamTextView()
        _ = tv.layoutManager  // pin TextKit 1, mirrors EditorSurface.makeNSView
        tv.string = text
        return tv
    }

    private func makeCoordinator(for tv: MaughamTextView) -> EditorCoordinator {
        let coord = EditorCoordinator(
            text: Binding(get: { tv.string }, set: { tv.string = $0 }),
            mode: ProseMode(),
            theme: .light, typography: .defaults,
            typewriterScroll: false,
            sentenceFocus: false, paragraphFocus: false)
        tv.delegate = coord
        tv.coordinator = coord
        coord.attach(to: tv)
        return coord
    }

    /// (a) A different view's appearance change (its first-mount callback) must
    /// NOT restyle an unrelated coordinator. This is the broadcast defect.
    func test_otherViewAppearanceChange_doesNotRestyleThisCoordinator() {
        let tvA = makeMaughamTextView()
        let coordA = makeCoordinator(for: tvA)

        let tvB = makeMaughamTextView()
        _ = makeCoordinator(for: tvB)

        let before = coordA.applyAppearanceCount
        // Simulate view B mounting into a window (AppKit fires this on B).
        tvB.viewDidChangeEffectiveAppearance()

        XCTAssertEqual(coordA.applyAppearanceCount, before,
            "coordinator A must not restyle when a different view's appearance changes")
    }

    /// (b) A same-appearance change (the first-mount callback with the same
    /// light/dark value already in effect) is a no-op.
    func test_sameAppearanceChange_isNoOp() {
        let tv = makeMaughamTextView()
        let coord = makeCoordinator(for: tv)

        // Sync the baseline to whatever the current effective appearance is.
        tv.viewDidChangeEffectiveAppearance()
        let before = coord.applyAppearanceCount

        // A second callback with the SAME effective appearance must not restyle.
        tv.viewDidChangeEffectiveAppearance()

        XCTAssertEqual(coord.applyAppearanceCount, before,
            "an unchanged effective appearance must not trigger a restyle")
    }

    /// (c) Positive control: a REAL light↔dark change still restyles. This is the
    /// reason the appearance hook exists; deleting the broadcast must not break it.
    func test_realAppearanceChange_restyles() {
        let tv = makeMaughamTextView()
        let coord = makeCoordinator(for: tv)

        // Pin a known baseline (aqua), then flip to darkAqua.
        tv.appearance = NSAppearance(named: .aqua)
        tv.viewDidChangeEffectiveAppearance()
        let before = coord.applyAppearanceCount

        tv.appearance = NSAppearance(named: .darkAqua)
        tv.viewDidChangeEffectiveAppearance()

        XCTAssertEqual(coord.applyAppearanceCount, before + 1,
            "a genuine light↔dark change must restyle exactly once")
    }

    /// (d) `detach()` (called from `dismantleNSView` on teardown) releases the
    /// coordinator's view handle, drops the delegate wiring, and makes any
    /// residual appearance/restyle call a no-op — so a lingering coordinator
    /// holds no heavy text-view graph and does no work.
    func test_detach_releasesViewAndSilencesRestyle() {
        let tv = makeMaughamTextView()
        let coord = makeCoordinator(for: tv)
        XCTAssertTrue(coord.textView === tv)

        coord.detach()

        XCTAssertNil(coord.textView, "detach must drop the text-view reference")
        XCTAssertTrue(tv.delegate == nil, "detach must clear the delegate wiring")
        XCTAssertTrue(coord.isDetached)

        let before = coord.applyAppearanceCount
        coord.effectiveAppearanceDidChange()
        coord.applyAppearance(theme: .light, typography: .defaults)
        XCTAssertEqual(coord.applyAppearanceCount, before,
            "a detached coordinator must not restyle")
    }

    /// The coordinator holds no internal ARC cycle: once the only strong owner
    /// (SwiftUI, mimicked here by the local `let`) drops it, the coordinator
    /// deallocates. This is what makes the observed post-window-close leak a
    /// SwiftUI scene-retention issue (SwiftUI keeps the closed window's scene
    /// storage), NOT a coordinator retain cycle — every back-reference into the
    /// coordinator (delegate, `textView`, overlay/gutter `coordinator`, the NC
    /// observers, the async Tasks) is already `weak`/`[weak self]`.
    ///
    /// The AppKit `NSTextView` itself is deliberately NOT asserted to deallocate
    /// here: a headless `NSTextView` is retained by AppKit's text-input /
    /// spell-checking machinery past a local `autoreleasepool`, which makes a
    /// text-view dealloc assertion flaky and unrelated to our ownership. What we
    /// pin instead is that `detach()` drops the coordinator's handle to the view
    /// (see `test_detach_releasesViewAndSilencesRestyle`).
    func test_coordinatorHasNoInternalRetainCycle() {
        weak var weakCoord: EditorCoordinator?
        autoreleasepool {
            let tv = makeMaughamTextView()
            let coord = makeCoordinator(for: tv)
            weakCoord = coord
            coord.detach()
        }
        XCTAssertNil(weakCoord, "coordinator must not be retained by any internal cycle")
    }
}
