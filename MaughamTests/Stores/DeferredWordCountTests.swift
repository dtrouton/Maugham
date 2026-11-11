// MaughamTests/Stores/DeferredWordCountTests.swift
import XCTest
import AppKit
@testable import Maugham

/// **The word count leaves the keystroke** (typing loop plan 1, Task 1).
///
/// A keystroke keeps the burst's latest text and does the session
/// bookkeeping; the whole-document count runs once, at the trailing edge or
/// when a reader needs the total as final (`DocumentStore.settleWordCount()`).
/// These pin both halves: nothing is counted per key, and no final reader —
/// quit, a piece switch, another device's words — sees a total the burst has
/// not reached.
@MainActor
final class DeferredWordCountTests: XCTestCase {

    func test_aBurstCountsNothingUntilItSettles_thenOnce() async throws {
        let h = try await EditorIntegrationHarness.withRealDocument()
        let before = h.documentStore.wordCountRunCount

        for c in "the quick brown fox jumps over" { h.harness.typeCharacter(c) }

        XCTAssertEqual(h.documentStore.wordCountRunCount - before, 0,
            "a keystroke counts nothing; the burst is counted when it settles")

        h.documentStore.settleWordCount()
        XCTAssertEqual(h.documentStore.wordCountRunCount - before, 1,
            "one settle counts the burst once")

        h.documentStore.settleWordCount()
        XCTAssertEqual(h.documentStore.wordCountRunCount - before, 1,
            "a settle with nothing pending counts nothing")

        await h.documentStore.close()
    }

    func test_theTrailingEdgeSettlesOnItsOwn() async throws {
        let h = try await EditorIntegrationHarness.withRealDocument()
        h.documentStore.wordCountSettleDelay = .zero

        await h.harness.typeString("Hello world.")
        await h.documentStore.wordCountSettleScheduler.flush()

        XCTAssertGreaterThan(h.projectStore.projectWordCount, 0,
            "the trailing edge records the burst's count with no reader asking")

        await h.documentStore.close()
    }

    func test_aBurstThenQuit_landsItsWordsInTheSessionEvent() async throws {
        let h = try await EditorIntegrationHarness.withRealDocument()

        await h.harness.typeString("one two three")
        await h.documentStore.flushSessionOnQuit()

        let log = try await h.documentStore.loadSessionLog()
        XCTAssertEqual(log.events.count, 1)
        XCTAssertEqual(log.events.last?.wordsNet, 3,
            "⌘Q inside the settle delay keeps the burst's words")

        await h.documentStore.close()
    }

    func test_switchingPieceMidBurst_recordsTheFirstPiecesCount() async throws {
        let h = try await EditorIntegrationHarness.withRealDocument()
        let ds = h.documentStore
        let mode = ProseMode()

        ds.recordEditorTextWrite(
            documentId: "piece-a", newText: "a b", mode: mode, store: h.projectStore)
        ds.recordEditorTextWrite(
            documentId: "piece-b", newText: "c", mode: mode, store: h.projectStore)
        ds.settleWordCount()

        XCTAssertEqual(h.projectStore.cachedWordCount(for: "piece-a"), 2,
            "A's burst is counted for A before B's first keystroke is taken")
        XCTAssertEqual(h.projectStore.cachedWordCount(for: "piece-b"), 1)
        XCTAssertEqual(ds.liveSessionWordsNet, 3, "the session delta is the sum")

        await ds.close()
    }

    func test_wordsArrivingMidBurstAreNotTheWriters() async throws {
        let h = try await EditorIntegrationHarness.withRealDocument()
        let ds = h.documentStore

        await h.harness.typeString("two words")

        // Another device's piece lands while the burst is unsettled.
        let other = "piece-elsewhere"
        let prior = h.projectStore.cachedWordCount(for: other) ?? 0
        h.projectStore.recordWordCount(forDocumentId: other, wordCount: prior + 5)
        ds.excludeForeignWords(5)

        ds.settleWordCount()
        XCTAssertEqual(ds.liveSessionWordsNet, 2,
            "typed words stay the writer's; arrived words are excluded; "
            + "neither is counted twice")

        await ds.close()
    }

    func test_typingInsideOneWordDoesNotInvalidateTheSessionReaders() async throws {
        let h = try await EditorIntegrationHarness.withRealDocument()
        let ds = h.documentStore

        // A session under way, settled, before observation starts.
        h.harness.typeCharacter("w")
        ds.settleWordCount()

        final class Flag: @unchecked Sendable { var fired = false }
        let inWord = Flag()
        withObservationTracking {
            _ = ds.liveSessionWordsNet
        } onChange: {
            inWord.fired = true
        }
        for c in "ordsmithed" { h.harness.typeCharacter(c) }
        ds.settleWordCount()
        XCTAssertFalse(inWord.fired,
            "keystrokes inside one word leave the session readers alone")

        let newWord = Flag()
        withObservationTracking {
            _ = ds.liveSessionWordsNet
        } onChange: {
            newWord.fired = true
        }
        for c in " again" { h.harness.typeCharacter(c) }
        ds.settleWordCount()
        XCTAssertTrue(newWord.fired,
            "a settle that moves the total invalidates the session readers")

        await ds.close()
    }

    func test_theSessionStillStartsAndRearmsOnEveryKeystroke() async throws {
        let h = try await EditorIntegrationHarness.withRealDocument()

        h.harness.typeCharacter("a")

        XCTAssertNotNil(h.documentStore.currentSessionStart,
            "the session starts on the keystroke, not on the settle")

        await h.documentStore.close()
    }
}
