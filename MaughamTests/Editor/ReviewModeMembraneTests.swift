import XCTest
import SwiftUI
import AppKit
import MaughamCore
@testable import Maugham

final class ReviewModeMembraneTests: XCTestCase {
    func test_reviewMode_disallowsTextMutation() {
        XCTAssertFalse(EditorEditPolicy.allowsTextMutation(isReviewMode: true))
        XCTAssertTrue(EditorEditPolicy.allowsTextMutation(isReviewMode: false))
    }

    /// Bug B regression: the synchronous membrane flip must take effect BEFORE
    /// the next key event, not after a SwiftUI render round-trip. `setReviewMode`
    /// is the same synchronous mutator the ⌘⌥R observer drives; once it has run,
    /// `shouldChangeTextIn` (the single mutation choke point AppKit funnels typing
    /// / paste / delete / Enter through) must reject every mutation. Before the
    /// fix, `isReviewMode` only flipped in updateNSView, so a fast Enter right
    /// after ⌘⌥R slipped a newline through.
    @MainActor
    func test_setReviewMode_blocksMutationImmediately() {
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

        // Before entering review, a mutation (e.g. typing a newline) is allowed.
        XCTAssertTrue(
            coordinator.textView(
                tv,
                shouldChangeTextIn: NSRange(location: 5, length: 0),
                replacementString: "\n"),
            "edits must pass through before review mode is on")

        // The synchronous flip (the path the ⌘⌥R observer drives).
        coordinator.setReviewMode(true)

        // Immediately after — no render round-trip — the membrane must block.
        XCTAssertFalse(
            coordinator.textView(
                tv,
                shouldChangeTextIn: NSRange(location: 5, length: 0),
                replacementString: "\n"),
            "after the synchronous review flip the membrane must block the very next keystroke")

        // Leaving review re-opens the membrane.
        coordinator.setReviewMode(false)
        XCTAssertTrue(
            coordinator.textView(
                tv,
                shouldChangeTextIn: NSRange(location: 5, length: 0),
                replacementString: "\n"),
            "leaving review must restore normal editing")
    }

    /// First-toggle marks regression: when the ⌘⌥R observer flips review ON
    /// synchronously, the coordinator's stored `reviewAnnotations` is still empty
    /// (review was off, so EditorHost gated its derivation to []) and the real set
    /// only arrives on the NEXT SwiftUI render. `setReviewMode(true)` must PULL the
    /// current set from `reviewAnnotationsProvider` and resolve marks immediately,
    /// rather than waiting for the lagged `setReviewAnnotations` push — otherwise
    /// marks/rail are absent until a second toggle.
    @MainActor
    func test_enteringReview_pullsAnnotationsFromProvider_resolvesMarksSynchronously() {
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

        // A paragraph-level open annotation, exposed ONLY via the on-demand
        // provider — NOT via the lagged `setReviewAnnotations` push. This mirrors
        // the first-toggle state: the push hasn't happened yet.
        let ann = Annotation(
            id: "op1", kind: .comment, paragraphId: "ab12",
            body: "needs work", suggestedText: nil, priorText: nil,
            createdAt: Date(), createdBySession: nil,
            status: .open, userResponse: nil,
            resolvedAt: nil, isStale: false)
        coordinator.reviewAnnotationsProvider = { [ann] }
        // Rail anchoring needs a paragraph range; map the lone paragraph to [0,5).
        coordinator.reviewParagraphRangeProvider = { pid in
            pid == "ab12" ? NSRange(location: 0, length: 5) : nil
        }

        XCTAssertTrue(
            coordinator.resolvedReviewMarks.isEmpty,
            "no marks before entering review")

        // The synchronous flip (the ⌘⌥R observer path) — no render round-trip,
        // so no `setReviewAnnotations` push has occurred yet.
        coordinator.setReviewMode(true)

        XCTAssertEqual(
            coordinator.resolvedReviewMarks.count, 1,
            "entering review must pull the current annotation set from the provider and resolve marks immediately")
        XCTAssertEqual(coordinator.resolvedReviewMarks.first?.id, "op1")
    }

    /// Create-while-in-review regression: a reviewer who creates a Comment/Query/
    /// Suggest while ALREADY in review mode must see its mark + rail card appear
    /// immediately, with NO review toggle. `commitAnnotation` awaits the op-log
    /// append then calls `refreshReviewMarksFromProvider()`, which re-pulls the
    /// (now larger) set from `reviewAnnotationsProvider` and recomputes marks.
    /// Before the fix the SwiftUI observation→push chain off `annotationsVersion`
    /// did not fire promptly, so the just-created annotation only rendered after
    /// the reviewer toggled review off/on.
    @MainActor
    func test_refreshReviewMarksFromProvider_rendersNewlyCreatedAnnotation_withoutToggle() {
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

        // The provider's backing set — mutated to simulate a create persisting.
        final class Store { var annotations: [Annotation] = [] }
        let backing = Store()
        coordinator.reviewAnnotationsProvider = { backing.annotations }
        coordinator.reviewParagraphRangeProvider = { pid in
            pid == "ab12" ? NSRange(location: 0, length: 5) : nil
        }

        // Enter review with NO annotations yet — no marks.
        coordinator.setReviewMode(true)
        XCTAssertTrue(
            coordinator.resolvedReviewMarks.isEmpty,
            "no marks before any annotation exists")

        // Simulate the create completing: the op-log append has landed, so the
        // provider now returns the new annotation. (In production this mutation
        // is the awaited `doc.addReviewerAnnotation`; here we mutate the backing
        // store directly to model "the persist finished".)
        backing.annotations = [
            Annotation(
                id: "op1", kind: .comment, paragraphId: "ab12",
                body: "needs work", suggestedText: nil, priorText: nil,
                createdAt: Date(), createdBySession: nil,
                status: .open, userResponse: nil,
                resolvedAt: nil, isStale: false)
        ]

        // The refresh the commit flow invokes after awaiting the append.
        coordinator.refreshReviewMarksFromProvider()

        XCTAssertEqual(
            coordinator.resolvedReviewMarks.count, 1,
            "creating an annotation while in review must resolve its mark immediately (no toggle)")
        XCTAssertEqual(coordinator.resolvedReviewMarks.first?.id, "op1")
    }

    /// The refresh is review-mode-gated: when review is OFF the provider is never
    /// invoked (no per-keystroke / out-of-review derivation).
    @MainActor
    func test_refreshReviewMarksFromProvider_isNoOpWhenReviewOff() {
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

        var providerCalls = 0
        coordinator.reviewAnnotationsProvider = {
            providerCalls += 1
            return []
        }

        // Review is OFF — refresh must not call the provider.
        coordinator.refreshReviewMarksFromProvider()
        XCTAssertEqual(providerCalls, 0,
            "refresh must be a no-op (provider untouched) while review is off")
    }

    /// Span-precise navigation (Part 2): an annotation with a resolved span must
    /// select that EXACT range, not just scroll to the paragraph.
    @MainActor
    func test_navigateToAnnotation_selectsResolvedSpan() {
        final class TextBox { var value = "Hello brave new world" }
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

        // A span-anchored comment covering "brave" (chars 6..<11), exposed via
        // the provider with a paragraph→display-text + range mapping so
        // recompute resolves an absoluteRange.
        let ann = Annotation(
            id: "op1", kind: .comment, paragraphId: "ab12",
            body: "word choice",
            suggestedText: nil, priorText: nil,
            createdAt: Date(), createdBySession: nil,
            status: .open, userResponse: nil,
            resolvedAt: nil, isStale: false,
            resolvedSpanRange: 6..<11)
        coordinator.reviewAnnotationsProvider = { [ann] }
        coordinator.reviewParagraphRangeProvider = { pid in
            pid == "ab12" ? NSRange(location: 0, length: 21) : nil
        }
        coordinator.reviewParagraphTextProvider = { pid in
            pid == "ab12" ? "Hello brave new world" : nil
        }
        coordinator.setReviewMode(true)

        guard let mark = coordinator.resolvedReviewMarks.first,
              let range = mark.absoluteRange else {
            return XCTFail("expected a resolved span for the comment")
        }
        XCTAssertEqual(range, NSRange(location: 6, length: 5))

        coordinator.navigateToAnnotation(
            id: "op1", fallbackParagraphId: "ab12", in: tv)
        XCTAssertEqual(
            tv.selectedRange(), NSRange(location: 6, length: 5),
            "navigation must select the exact resolved span")
    }

    /// Fallback (Part 2): a paragraph-level annotation (no resolved span) selects
    /// a length-0 cursor at the paragraph start.
    @MainActor
    func test_navigateToAnnotation_fallsBackToParagraphStart() {
        final class TextBox { var value = "Hello brave new world" }
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

        // No resolved span in the marks; the paragraph range provider drives the
        // fallback (same closure the legacy paragraph-nav handler uses).
        coordinator.paragraphRangeProvider = { pid in
            pid == "ab12" ? NSRange(location: 6, length: 15) : nil
        }
        coordinator.navigateToAnnotation(
            id: "missing", fallbackParagraphId: "ab12", in: tv)
        XCTAssertEqual(
            tv.selectedRange(), NSRange(location: 6, length: 0),
            "fallback must place a length-0 cursor at the paragraph start")
    }
}
