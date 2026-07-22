// MaughamTests/Editor/TranslationReviewEventTests.swift
import XCTest
import AppKit
import MaughamCore
@testable import Maugham

/// Task 13: the translation-review entry/exit events + the language-picker
/// indicator's pure label helper.
///
/// The event round-trips go through the REAL `MaughamEvent.observe` wrapper
/// (ADR 0021) — same delivery path production uses — so the payload language
/// and the `.keyWindow` scoping are pinned end-to-end, not just at the
/// `shouldDeliver` filter. Key-window STATUS isn't grantable headless, so the
/// receiver context's `isWindowKey` is forced (the established idiom from
/// `MaughamEventLivenessTests`).
@MainActor
final class TranslationReviewEventTests: XCTestCase {

    private func keyContext(_ isKey: Bool) -> EventReceiverContext {
        EventReceiverContext(kind: .keyWindow, isWindowLive: true, isWindowKey: isKey)
    }

    // MARK: - Enter / exit event round-trips

    func test_enterTranslationReview_deliversLanguagePayload() {
        var received: String?
        let token = MaughamEvent.observe(
            .maughamEnterTranslationReview,
            context: { [self] in keyContext(true) },
            handler: { received = $0.userInfo?["language"] as? String })
        defer { NotificationCenter.default.removeObserver(token) }

        MaughamEvent.post(.maughamEnterTranslationReview, to: .keyWindow,
                          payload: ["language": "es"])

        XCTAssertEqual(received, "es",
            "entering translation review must carry the chosen BCP-47 language tag")
    }

    func test_exitTranslationReview_delivers() {
        var fired = 0
        let token = MaughamEvent.observe(
            .maughamExitTranslationReview,
            context: { [self] in keyContext(true) },
            handler: { _ in fired += 1 })
        defer { NotificationCenter.default.removeObserver(token) }

        MaughamEvent.post(.maughamExitTranslationReview, to: .keyWindow)

        XCTAssertEqual(fired, 1, "exit must deliver to the key-window receiver")
    }

    func test_enterTranslationReview_droppedWhenWindowNotKey() {
        // `.keyWindow` scoping: a non-key window's receiver must NOT act — this
        // is the same drop rule as ⌘⌥R review-mode toggle (menu-command class).
        var fired = 0
        let token = MaughamEvent.observe(
            .maughamEnterTranslationReview,
            context: { [self] in keyContext(false) },
            handler: { _ in fired += 1 })
        defer { NotificationCenter.default.removeObserver(token) }

        MaughamEvent.post(.maughamEnterTranslationReview, to: .keyWindow,
                          payload: ["language": "fr"])

        XCTAssertEqual(fired, 0,
            "a non-key window must not enter translation review on a key-window post")
    }

    func test_showTranslationPicker_delivers() {
        var fired = 0
        let token = MaughamEvent.observe(
            .maughamShowTranslationPicker,
            context: { [self] in keyContext(true) },
            handler: { _ in fired += 1 })
        defer { NotificationCenter.default.removeObserver(token) }

        MaughamEvent.post(.maughamShowTranslationPicker, to: .keyWindow)

        XCTAssertEqual(fired, 1, "the picker command must reach the key window")
    }

    // MARK: - I1: translation-did-update refresh event (project-scoped)

    private func projectContext(_ id: String) -> EventReceiverContext {
        EventReceiverContext(kind: .project(id: id), isWindowLive: true, isWindowKey: false)
    }

    func test_translationDidUpdate_deliversToLiveWindowOnProject() {
        var receivedDoc: String?
        var receivedLang: String?
        let token = MaughamEvent.observe(
            .maughamTranslationDidUpdate,
            context: { [self] in projectContext("proj-1") },
            handler: {
                receivedDoc = $0.userInfo?["document_id"] as? String
                receivedLang = $0.userInfo?["language"] as? String
            })
        defer { NotificationCenter.default.removeObserver(token) }

        MaughamEvent.post(.maughamTranslationDidUpdate, to: .project(id: "proj-1"),
                          payload: ["document_id": "doc-9", "language": "es"])

        XCTAssertEqual(receivedDoc, "doc-9",
            "the refresh event must name the affected document so EditorHost can guard on it")
        XCTAssertEqual(receivedLang, "es")
    }

    func test_translationDidUpdate_droppedForOtherProject() {
        var fired = 0
        let token = MaughamEvent.observe(
            .maughamTranslationDidUpdate,
            context: { [self] in projectContext("proj-1") },
            handler: { _ in fired += 1 })
        defer { NotificationCenter.default.removeObserver(token) }

        MaughamEvent.post(.maughamTranslationDidUpdate, to: .project(id: "proj-2"),
                          payload: ["document_id": "doc-9", "language": "es"])

        XCTAssertEqual(fired, 0,
            "a translation write in another project must not refresh this project's review")
    }

    // MARK: - Indicator display-label helper (pure)

    func test_displayLabel_formatsLocalizedNameWithTag() {
        let label = TranslationReviewIndicator.displayLabel(forLanguageTag: "en")
        XCTAssertTrue(label.contains("(en)"),
            "the raw tag must always be visible in parentheses: \(label)")
        if let localized = Locale.current.localizedString(forLanguageCode: "en") {
            XCTAssertEqual(label, "\(localized) (en)")
        }
    }

    func test_displayLabel_fallsBackToRawTagWhenNoLocalizedName() {
        // A tag with no localized name falls back to the raw tag alone.
        let nonsense = "zzzz"
        let label = TranslationReviewIndicator.displayLabel(forLanguageTag: nonsense)
        XCTAssertTrue(label.contains(nonsense),
            "the raw tag must survive into the label even with no localized name")
        if Locale.current.localizedString(forLanguageCode: nonsense) == nil {
            XCTAssertEqual(label, nonsense,
                "with no localized name the label is exactly the raw tag")
        }
    }

    // MARK: - Stale-count helper (pure)

    func test_staleCount_countsOnlyStaleEntries() {
        let entries = [
            TranslationBadgeLayout.Entry(paragraphId: "a", text: "x", status: .fresh),
            TranslationBadgeLayout.Entry(paragraphId: "b", text: "y", status: .stale),
            TranslationBadgeLayout.Entry(paragraphId: "c", text: "z", status: .stale),
            TranslationBadgeLayout.Entry(paragraphId: "d", text: "w", status: .missing),
        ]
        XCTAssertEqual(TranslationReviewIndicator.staleCount(in: entries), 2)
        XCTAssertEqual(TranslationReviewIndicator.staleCount(in: []), 0)
    }
}
