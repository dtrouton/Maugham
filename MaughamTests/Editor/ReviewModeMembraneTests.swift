import XCTest
import SwiftUI
import AppKit
import MaughamCore
@testable import Maugham

final class ReviewModeMembraneTests: XCTestCase {
    func test_reviewMode_disallowsTextMutation() {
        XCTAssertFalse(EditorEditPolicy.allowsTextMutation(
            isReviewMode: true, lockEditing: false))
        XCTAssertTrue(EditorEditPolicy.allowsTextMutation(
            isReviewMode: false, lockEditing: false))
    }

    /// Role lock is the hard floor: a reviewer/unknown is `lockEditing == true`,
    /// so even with the manual review render toggled OFF (`isReviewMode == false`)
    /// the membrane must still block. The manual toggle can never win over the
    /// role lock — this is what stops a reviewer's ⌘⌥R from unlocking the text.
    func test_lockEditing_blocksEvenWhenReviewRenderOff() {
        XCTAssertFalse(EditorEditPolicy.allowsTextMutation(
            isReviewMode: false, lockEditing: true),
            "a locked (non-author) user must be blocked even with the review render off")
        XCTAssertFalse(EditorEditPolicy.allowsTextMutation(
            isReviewMode: true, lockEditing: true))
    }

    /// The coordinator's `setLockEditing` flips the hard lock independently of the
    /// review render. With the lock on and review render OFF, the membrane must
    /// still reject mutation — a reviewer toggling ⌘⌥R off cannot type.
    @MainActor
    func test_setLockEditing_blocksMutationWithReviewRenderOff() {
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

        // Hard lock on, but review RENDER off (the reviewer-toggled-⌘⌥R-off case).
        coordinator.setLockEditing(true)
        coordinator.setReviewMode(false)

        XCTAssertFalse(
            coordinator.textView(
                tv,
                shouldChangeTextIn: NSRange(location: 5, length: 0),
                replacementString: "\n"),
            "a locked reviewer must not be able to mutate text even with the review render off")

        // Clearing the lock (e.g. role re-resolved to author) re-opens the membrane.
        coordinator.setLockEditing(false)
        XCTAssertTrue(
            coordinator.textView(
                tv,
                shouldChangeTextIn: NSRange(location: 5, length: 0),
                replacementString: "\n"),
            "clearing the role lock must restore normal editing")
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

    /// Resolved-posture push regression (the "can't edit my own doc until I flip
    /// pieces" bug), now via the control plane (ADR 0017): mutating the observed
    /// EditorControl unlocks the membrane in place — no key window, no notification.
    @MainActor
    func test_controlModelResolve_unlocksMembrane() async {
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

        let control = EditorControl()
        control.isReviewMode = true
        control.lockEditing = true
        coordinator.observeControl(control)   // open posture: locked

        XCTAssertFalse(
            coordinator.textView(tv, shouldChangeTextIn: NSRange(location: 5, length: 0),
                                 replacementString: "x"),
            "own doc opens locked while role unresolved")

        control.isReviewMode = false
        control.lockEditing = false
        try? await Task.sleep(for: .milliseconds(50))

        XCTAssertTrue(
            coordinator.textView(tv, shouldChangeTextIn: NSRange(location: 5, length: 0),
                                 replacementString: "x"),
            "role resolving to author must re-open the membrane in place")
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

/// **The membrane asked of the posture** (signed op log P3c Task 3): the
/// window's mirror (`EditorControlMirror.membrane`) and the statement editor's
/// lock (`StatementEditorHost.locksEditing`), each driven into a real
/// coordinator's `shouldChangeTextIn` — the one mutation choke point — in both
/// directions. No window; no press (tripwire 33).
@MainActor
final class PostureMembraneTests: XCTestCase {

    private var fixture: PostureFixture!

    override func setUp() async throws {
        fixture = try PostureFixture()
    }

    override func tearDown() async throws {
        fixture.tearDown()
        fixture = nil
    }

    /// A coordinator over "Hello world", with `membrane` applied the way
    /// `applyControl` applies the control model.
    private func typingReaches(
        lockEditing: Bool, isReviewMode: Bool
    ) -> (accepted: Bool, textView: NSTextView) {
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
        coordinator.setLockEditing(lockEditing)
        coordinator.setReviewMode(isReviewMode)
        let accepted = coordinator.textView(
            tv, shouldChangeTextIn: NSRange(location: 5, length: 0),
            replacementString: "X")
        return (accepted, tv)
    }

    // MARK: - The pure decision

    func test_theMirrorsDecisionOverItsInputs() {
        let author = Posture(.unrestricted)
        let reviewer = Posture(LocalWritePermit(
            permit: .reviewer, actor: .author, documentClass: .piece("d")))
        let ownPiece = Posture(LocalWritePermit(
            permit: .author(.pieces(["d"])), actor: .author, documentClass: .piece("d")))

        func m(_ p: Posture?, manual: Bool = false, share: Bool = false)
            -> EditorControlMirror.Membrane {
            EditorControlMirror.membrane(posture: p, manualReview: manual, shareIsReadOnly: share)
        }
        XCTAssertEqual(m(author), .init(lockEditing: false, isReviewMode: false))
        XCTAssertEqual(m(author, manual: true), .init(lockEditing: false, isReviewMode: true),
                       "an author's ⌘⌥⇧R is the render, never the lock")
        XCTAssertEqual(m(reviewer), .init(lockEditing: true, isReviewMode: true),
                       "a reviewer's Mac opens locked, in review mode")
        XCTAssertEqual(m(ownPiece), .init(lockEditing: false, isReviewMode: false),
                       "restricted (may not start a piece) is not locked — ruling E")
        XCTAssertEqual(m(author, share: true), .init(lockEditing: true, isReviewMode: false),
                       "a read-only share is its own lock and claims no role")
        XCTAssertEqual(m(nil), .init(lockEditing: false, isReviewMode: false),
                       "no manuscript document: nothing to lock")
        XCTAssertEqual(m(.settling), .init(lockEditing: true, isReviewMode: true),
                       "undecided LOCKS: a verb appearing that must not is the worse error")
    }

    // MARK: - Both directions, mid-session, through the door

    func test_aReviewerCannotTypeAndAPromotionLetsHerWithNoReopen() async throws {
        let store = try await fixture.openAs(.reviewer)
        let locked = EditorControlMirror.membrane(
            posture: store.posture(forDocId: PostureFixture.docId),
            manualReview: false, shareIsReadOnly: false)
        let refused = typingReaches(
            lockEditing: locked.lockEditing, isReviewMode: locked.isReviewMode)
        XCTAssertFalse(refused.accepted, "a reviewer's keystroke is refused")
        XCTAssertTrue(refused.textView.isEditable, "isEditable is never touched")
        XCTAssertTrue(refused.textView.isSelectable, "selection and copy still work")
        refused.textView.setSelectedRange(NSRange(location: 0, length: 5))
        XCTAssertEqual(refused.textView.selectedRange(), NSRange(location: 0, length: 5))

        try await fixture.changeMyPermit(to: .bookAuthor, store: store)
        let open = EditorControlMirror.membrane(
            posture: store.posture(forDocId: PostureFixture.docId),
            manualReview: false, shareIsReadOnly: false)
        XCTAssertNotEqual(open, locked, "the mirror sees the promotion as a change")
        XCTAssertTrue(typingReaches(
            lockEditing: open.lockEditing, isReviewMode: open.isReviewMode).accepted,
            "promoted mid-session: her typing is accepted")
    }

    // MARK: - The statement editor

    private func statementLock(
        _ store: DocumentStore, _ kind: Statement.Kind, _ scope: Statement.Scope
    ) throws -> Bool {
        let manifestURL = fixture.projectURL.appendingPathComponent(ProjectManifest.fileName)
        let manifest = try ProjectManifest.makeDecoder()
            .decode(ProjectManifest.self, from: Data(contentsOf: manifestURL))
        let docId = StatementEditorHost.postureDocId(
            kind: kind, scope: scope, statements: manifest.statements)
        return StatementEditorHost.locksEditing(store.posture(forDocId: docId))
    }

    func test_aPiecesAuthorCannotEditTheProjectsStatement() async throws {
        let store = try await fixture.openAs(
            .author(.pieces([PostureFixture.docId])), statements: true)

        let projectLocked = try statementLock(store, .intent, .project)
        XCTAssertTrue(projectLocked, "the project's statement is the book author's")
        XCTAssertFalse(typingReaches(lockEditing: projectLocked, isReviewMode: false).accepted,
                       "and the statement editor's membrane refuses her keystroke")

        XCTAssertFalse(try statementLock(store, .intent, .document(PostureFixture.docId)),
                       "her own piece's statement is hers")
        XCTAssertTrue(try statementLock(store, .visualLanguage, .project),
                      "a project statement with no file yet is the book author's too")
        XCTAssertFalse(try statementLock(store, .visualLanguage, .document(PostureFixture.docId)),
                       "and her piece's, with no file yet, is hers")
    }

    func test_theBookAuthorEditsEveryStatement() async throws {
        let store = try await fixture.openAs(.bookAuthor, statements: true)
        XCTAssertFalse(try statementLock(store, .intent, .project))
        XCTAssertFalse(try statementLock(store, .visualLanguage, .project))
        XCTAssertFalse(try statementLock(store, .intent, .document(PostureFixture.docId)))
        XCTAssertTrue(typingReaches(lockEditing: false, isReviewMode: false).accepted)
    }

    /// Mid-session, both directions: demoted to a pieces-author the open
    /// project statement locks; promoted back, it opens.
    func test_theStatementLockFollowsThePermitMidSession() async throws {
        let store = try await fixture.openAs(.bookAuthor, statements: true)
        XCTAssertFalse(try statementLock(store, .intent, .project))
        try await fixture.changeMyPermit(
            to: .author(.pieces([PostureFixture.docId])), store: store)
        XCTAssertTrue(try statementLock(store, .intent, .project))
        try await fixture.changeMyPermit(to: .bookAuthor, store: store)
        XCTAssertFalse(try statementLock(store, .intent, .project))
    }
}
