// MaughamTests/TranslationRevealTests.swift
import XCTest
import AppKit
@testable import Maugham

/// **A departure or disagreement row as a way back into the manuscript**
/// (translation pipeline P4 Task 5).
///
/// Three pure facts — the plan, the payload, the two posts — because the window
/// side of this feature is a `ViewModifier`'s `.onKeyWindowCommand` and a
/// ViewBuilder arm's closure, and neither is reachable headlessly. Those two are
/// pinned by `TripwireGrepTests` instead.
///
/// The round trip goes through the REAL `MaughamEvent` post/observe pair
/// (ADR 0021) rather than a hand-built `userInfo`, so the `.keyWindow` scope is
/// pinned end to end and not at the payload alone. Key-window status isn't
/// grantable headless, so the receiver context's `isWindowKey` is forced — the
/// established idiom from `TranslationReviewEventTests`.
@MainActor
final class TranslationRevealTests: XCTestCase {

    private let reveal = TranslationReveal(
        docId: "doc-2", language: "es", paragraphId: "a1b2")

    func test_aRevealOnTheOpenChapterIsNowAndOnAnotherIsAfterSelectingIt() {
        XCTAssertEqual(
            TranslationReveal.plan(reveal, activeDocId: "doc-2"), .now,
            "the chapter the reveal names is already the open one — there is "
            + "nothing to select first")
        XCTAssertEqual(
            TranslationReveal.plan(reveal, activeDocId: "doc-1"),
            .afterSelecting(.item("doc-2")),
            "another chapter is open, so the reveal has to select its own first")
        XCTAssertEqual(
            TranslationReveal.plan(reveal, activeDocId: BinderSubject.noDocumentSubject),
            .afterSelecting(.item("doc-2")),
            "the sentinel names no document at all, so it is never the chapter "
            + "the reveal is about")
    }

    func test_theRevealRoundTripsThroughItsPayload() {
        var received: Notification?
        let token = MaughamEvent.observe(
            .maughamRevealTranslation,
            context: {
                EventReceiverContext(kind: .keyWindow, isWindowLive: true,
                                     isWindowKey: true)
            },
            handler: { received = $0 })
        defer { NotificationCenter.default.removeObserver(token) }

        TranslationReveal.post(reveal)

        XCTAssertEqual(
            TranslationReveal.decode(received?.userInfo), reveal,
            "a reveal posted to the key window must decode back to itself — the "
            + "poster and the window are different files and the payload keys "
            + "have one spelling on purpose")
        XCTAssertNil(
            TranslationReveal.decode(["language": "es"]),
            "a payload naming neither the document nor the paragraph is not a "
            + "reveal, and must decode to nothing rather than a half-built one")
    }

    func test_performEntersReviewForTheLanguageThenNavigatesToTheParagraph() async {
        var posts: [(Notification.Name, [String: Any])] = []
        await TranslationReveal.perform(reveal) { posts.append(($0, $1)) }

        XCTAssertEqual(
            posts.map(\.0),
            [.maughamEnterTranslationReview, .maughamNavigateToParagraph],
            "the order is the whole of it: the surface has to be the translation "
            + "before a paragraph in it is worth scrolling to")
        XCTAssertEqual(posts[0].1["language"] as? String, "es",
            "entering review carries the edition the row belongs to")
        XCTAssertEqual(posts[1].1["paragraph_id"] as? String, "a1b2",
            "the navigation carries the row's own paragraph")
    }

    /// **The order alone was not enough, and this is the test that says so**
    /// (fix round 1).
    ///
    /// `.maughamEnterTranslationReview` only writes `translationLanguage`; the
    /// translated buffer arrives on the NEXT SwiftUI body pass. Posted back to
    /// back, the navigate scrolls the source text and the swap discards the
    /// scroll, so every reveal opens the edition at the top. Production's `ready`
    /// hook is what closes that window, and a hook nothing awaits is a hook that
    /// does not work — so this holds `ready` open and proves the navigate has
    /// not gone while it is held.
    func test_theNavigateDoesNotGoUntilTheReadyHookHasReturned() async {
        let probe = RevealProbe()

        let performing = Task { @MainActor in
            await TranslationReveal.perform(
                reveal,
                ready: {
                    probe.readyEntered = true
                    while !probe.released {
                        try? await Task.sleep(for: .milliseconds(5))
                    }
                },
                post: { name, _ in probe.posts.append(name) })
        }
        defer { performing.cancel() }

        guard await probe.waitUntilReadyEntered() else {
            return XCTFail("perform never reached its ready hook")
        }
        XCTAssertEqual(probe.posts, [.maughamEnterTranslationReview],
            "entering review has gone, and the navigate must still be waiting: "
            + "posting it now would scroll the source buffer that the surface "
            + "swap is about to throw away")

        probe.released = true
        await performing.value

        XCTAssertEqual(
            probe.posts,
            [.maughamEnterTranslationReview, .maughamNavigateToParagraph],
            "the navigate goes once ready has returned, and only then")
    }
}

/// The gate `test_theNavigateDoesNotGoUntilTheReadyHookHasReturned` holds
/// `perform` open with. A `@MainActor` class rather than captured local `var`s,
/// which a `Task`'s closure cannot mutate.
@MainActor
private final class RevealProbe {
    var posts: [Notification.Name] = []
    var readyEntered = false
    var released = false

    /// Yield until `perform` has reached the hook, bounded so a broken `perform`
    /// fails the test in a second rather than hanging on XCTest's own allowance.
    func waitUntilReadyEntered() async -> Bool {
        for _ in 0..<200 {
            if readyEntered { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return readyEntered
    }
}
