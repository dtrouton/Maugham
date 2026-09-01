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

    func test_performEntersReviewForTheLanguageThenNavigatesToTheParagraph() {
        var posts: [(Notification.Name, [String: Any])] = []
        TranslationReveal.perform(reveal) { posts.append(($0, $1)) }

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
}
