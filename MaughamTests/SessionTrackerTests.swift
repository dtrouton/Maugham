import XCTest
@testable import Maugham

@MainActor
final class SessionTrackerTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    private let idleThreshold: TimeInterval = 30 * 60  // 30 min

    func test_initialState_noActiveSession() {
        let tracker = SessionTracker()
        XCTAssertNil(tracker.activeSession)
    }

    func test_recordTextChange_startsSession() {
        let tracker = SessionTracker()
        tracker.recordTextChange(at: t0, projectWordCount: 100)
        XCTAssertNotNil(tracker.activeSession)
        XCTAssertEqual(tracker.activeSession?.startWordCount, 100)
        XCTAssertEqual(tracker.activeSession?.startedAt, t0)
    }

    func test_recordTextChange_doesNotResetSession() {
        let tracker = SessionTracker()
        tracker.recordTextChange(at: t0, projectWordCount: 100)
        let firstStart = tracker.activeSession?.startedAt
        tracker.recordTextChange(
            at: t0.addingTimeInterval(60), projectWordCount: 110)
        XCTAssertEqual(tracker.activeSession?.startedAt, firstStart)
        // Word count snapshot should NOT update; only at session start.
        XCTAssertEqual(tracker.activeSession?.startWordCount, 100)
    }

    func test_endSessionIfIdle_returnsEventForActiveSession() {
        let tracker = SessionTracker()
        tracker.recordTextChange(at: t0, projectWordCount: 100)
        tracker.recordTextChange(
            at: t0.addingTimeInterval(120), projectWordCount: 250)
        let event = tracker.endSessionIfIdle(
            at: t0.addingTimeInterval(120 + idleThreshold),
            currentProjectWordCount: 250)
        XCTAssertNotNil(event)
        XCTAssertEqual(event?.wordsNet, 150)
        XCTAssertEqual(event?.startedAt, t0)
        XCTAssertEqual(event?.endedAt, t0.addingTimeInterval(120))
        XCTAssertNil(tracker.activeSession)
    }

    func test_endSessionIfIdle_withNoActiveSession_returnsNil() {
        let tracker = SessionTracker()
        let event = tracker.endSessionIfIdle(
            at: t0, currentProjectWordCount: 100)
        XCTAssertNil(event)
    }

    func test_endSessionImmediately_flushesActiveSession() {
        let tracker = SessionTracker()
        tracker.recordTextChange(at: t0, projectWordCount: 100)
        tracker.recordTextChange(
            at: t0.addingTimeInterval(60), projectWordCount: 175)
        let event = tracker.endSessionImmediately(
            at: t0.addingTimeInterval(60),
            currentProjectWordCount: 175)
        XCTAssertNotNil(event)
        XCTAssertEqual(event?.wordsNet, 75)
        XCTAssertNil(tracker.activeSession)
    }

    func test_negativeWordsNet_isPreserved() {
        // Writer deleted more than they wrote in this session.
        let tracker = SessionTracker()
        tracker.recordTextChange(at: t0, projectWordCount: 1000)
        let event = tracker.endSessionImmediately(
            at: t0.addingTimeInterval(60),
            currentProjectWordCount: 850)
        XCTAssertEqual(event?.wordsNet, -150)
    }
}
