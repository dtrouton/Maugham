import XCTest
import MaughamCore
import AppKit
import SwiftUI
@testable import Maugham

/// ARC-side proof underpinning the ADR 0021 scene-storage spike
/// (`docs/superpowers/notes/2026-07-02-scene-storage-spike.md`).
///
/// The spike's whole premise — "the post-window-close leak is SwiftUI
/// `WindowGroup` scene retention, NOT an ARC cycle on our side" — rests on the
/// claim that an `EditorCoordinator` whose only strong owner drops is released.
/// The window-close path itself is not headlessly drivable (SwiftUI scene
/// lifecycle), but the ARC claim is: if the coordinator held an internal retain
/// cycle, dropping every external strong ref would NOT free it, and no cheap
/// scene-storage lever could ever release it. These tests pin the opposite, so
/// the residual really is bounded, neutralised RAM (per the liveness guard), not
/// a bug we could fix in our own code.
@MainActor
final class EditorCoordinatorReleaseTests: XCTestCase {

    private func makeTextView(text: String = "") -> NSTextView {
        let storage = NSTextStorage(string: text)
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: 600, height: 600))
        layout.addTextContainer(container)
        return NSTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 600),
                          textContainer: container)
    }

    private func makeCoordinator(textView: NSTextView) -> EditorCoordinator {
        let binding: Binding<String> = .init(
            get: { textView.string },
            set: { textView.string = $0 })
        let coord = EditorCoordinator(
            text: binding, mode: ProseMode(),
            theme: .light, typography: .defaults,
            typewriterScroll: false,
            sentenceFocus: false, paragraphFocus: false)
        coord.attach(to: textView)
        return coord
    }

    /// The coordinator has no internal retain cycle: once the last external
    /// strong reference drops it is released, even while the text view it was
    /// attached to is still alive (the text view holds the coordinator only
    /// weakly — `delegate` and `MaughamTextView.coordinator` are both weak).
    func test_coordinatorReleasedWhenLastStrongRefDrops() {
        let tv = makeTextView(text: "Hello, world.")  // kept alive here
        weak var weakCoord: EditorCoordinator?
        autoreleasepool {
            var coord: EditorCoordinator? = makeCoordinator(textView: tv)
            weakCoord = coord
            XCTAssertNotNil(weakCoord)
            coord = nil  // drop the only strong owner
        }
        XCTAssertNil(
            weakCoord,
            "EditorCoordinator must have no internal retain cycle — dropping its "
            + "last strong reference releases it. If this fails, the post-close "
            + "leak is our bug, not SwiftUI scene retention.")
        _ = tv
    }

    /// `detach()` does not strand the coordinator: after tearing down (which nils
    /// its `textView`, cancels its Tasks, and removes its observer tokens) the
    /// coordinator is still released once its last strong ref drops. This is the
    /// ARC basis for "detach() neutralises the zombie" — teardown adds no cycle,
    /// so a coordinator SwiftUI later releases really does go away. (Full dealloc
    /// of the `NSTextView` itself is intentionally NOT asserted here: TextKit
    /// retains it through its own layout-manager/text-storage graph independent
    /// of our edge; the coordinator→textView release is pinned by
    /// `EditorAppearanceChangeTests.test_detach_releasesViewAndSilencesRestyle`.)
    func test_detachedCoordinatorStillReleased() {
        let tv = makeTextView(text: "Body text.")  // kept alive here
        weak var weakCoord: EditorCoordinator?
        autoreleasepool {
            var coord: EditorCoordinator? = makeCoordinator(textView: tv)
            weakCoord = coord
            coord?.detach()
            XCTAssertNotNil(weakCoord)
            coord = nil
        }
        XCTAssertNil(
            weakCoord,
            "detach() must not create a retain cycle — a detached coordinator is "
            + "still freed when SwiftUI releases its scene storage.")
        _ = tv
    }
}
