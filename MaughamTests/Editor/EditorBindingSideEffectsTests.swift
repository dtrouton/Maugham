// MaughamTests/Editor/EditorBindingSideEffectsTests.swift
import XCTest
import AppKit
@testable import Maugham

/// Integration tests that assert the EditorHost binding setter's
/// side-effects (recordEditorTextWrite via Document + DocumentStore +
/// ProjectStore) fire end-to-end when the user types. These are the
/// tests that would have caught the document-first-class regression
/// (commit b37609a, 2026-05-19) where the side-effect calls were
/// silently dropped — the unit tests in DocumentStoreEditorTextWriteTests
/// pass against the helper in isolation, but only end-to-end coverage
/// catches "EditorHost forgot to call the helper".
@MainActor
final class EditorBindingSideEffectsTests: XCTestCase {

    func test_typing_refreshesProjectWordCount() async throws {
        let h = try await EditorIntegrationHarness.withRealDocument()
        XCTAssertEqual(h.projectStore.projectWordCount, 0,
            "empty doc → zero project word count baseline")

        await h.harness.typeString("Hello world.")

        XCTAssertGreaterThan(h.projectStore.projectWordCount, 0,
            "typing must refresh ProjectStore.projectWordCount via " +
            "recordEditorTextWrite — if this fails, the EditorHost binding " +
            "setter has stopped calling recordEditorTextWrite")

        await h.documentStore.close()
    }

    func test_typing_startsLiveSession() async throws {
        let h = try await EditorIntegrationHarness.withRealDocument()
        XCTAssertNil(h.documentStore.currentSessionStart,
            "no session active before any typing")

        await h.harness.typeString("First sentence.")

        XCTAssertNotNil(h.documentStore.currentSessionStart,
            "typing must start a session via " +
            "DocumentStore.recordSessionActivity (called from " +
            "recordEditorTextWrite) — if this fails, SessionTracker is " +
            "no longer being pinged on text writes")

        await h.documentStore.close()
    }

    func test_typing_updatesLiveSessionWordsNet() async throws {
        let h = try await EditorIntegrationHarness.withRealDocument()

        await h.harness.typeString("One.")
        // First text write seeds the session baseline at the post-write
        // word count, so liveSessionWordsNet is 0 immediately after the
        // first write. Confirmed by DocumentStoreEditorTextWriteTests.
        XCTAssertEqual(h.documentStore.liveSessionWordsNet, 0,
            "first write establishes the session baseline; delta is 0")

        await h.harness.typeString(" Two three four five.")
        XCTAssertEqual(h.documentStore.liveSessionWordsNet, 4,
            "subsequent typing must accumulate in liveSessionWordsNet")

        await h.documentStore.close()
    }

    func test_typing_screenplayMode_alsoTracks() async throws {
        let h = try await EditorIntegrationHarness.withRealDocument(
            mode: ScreenplayMode())

        await h.harness.typeString("Hello world.")

        XCTAssertGreaterThan(h.projectStore.projectWordCount, 0,
            "screenplay mode must track word count too")
        XCTAssertNotNil(h.documentStore.currentSessionStart)

        await h.documentStore.close()
    }
}
