import XCTest
@testable import Maugham

final class SessionLogTests: XCTestCase {

    private func evt(_ id: String,
                     _ start: Date,
                     _ end: Date,
                     _ words: Int) -> SessionEvent {
        SessionEvent(id: id, startedAt: start, endedAt: end,
                     wordsNet: words, deviceId: nil)
    }

    func test_emptyLog_isEmpty() {
        XCTAssertTrue(SessionLog.empty.events.isEmpty)
        XCTAssertEqual(SessionLog.empty.schemaVersion, 1)
    }

    func test_codableRoundtrip() throws {
        let log = SessionLog(
            schemaVersion: 1,
            events: [evt("e1", Date(timeIntervalSince1970: 100),
                         Date(timeIntervalSince1970: 200), 50)])
        let data = try JSONEncoder().encode(log)
        let decoded = try JSONDecoder().decode(SessionLog.self, from: data)
        XCTAssertEqual(decoded, log)
    }

    func test_merge_unionsByEventId() {
        let e1 = evt("a", Date(timeIntervalSince1970: 100),
                     Date(timeIntervalSince1970: 200), 50)
        let e2 = evt("b", Date(timeIntervalSince1970: 300),
                     Date(timeIntervalSince1970: 400), 75)
        let e3 = evt("c", Date(timeIntervalSince1970: 500),
                     Date(timeIntervalSince1970: 600), 90)
        let local = SessionLog(schemaVersion: 1, events: [e1, e2])
        let cloud = SessionLog(schemaVersion: 1, events: [e2, e3])
        let merged = SessionLog.merged(local, cloud)
        XCTAssertEqual(merged.events.count, 3)
        XCTAssertEqual(Set(merged.events.map(\.id)), ["a", "b", "c"])
    }

    func test_merge_sortsByStartedAt() {
        let e1 = evt("a", Date(timeIntervalSince1970: 300),
                     Date(timeIntervalSince1970: 400), 1)
        let e2 = evt("b", Date(timeIntervalSince1970: 100),
                     Date(timeIntervalSince1970: 200), 1)
        let merged = SessionLog.merged(
            SessionLog(schemaVersion: 1, events: [e1]),
            SessionLog(schemaVersion: 1, events: [e2]))
        XCTAssertEqual(merged.events.map(\.id), ["b", "a"])
    }

    func test_wordsToday_sumsTodayEventsOnly() {
        // Pin "now" to noon so we have safe headroom on both sides — the
        // older test used `Date()` and broke when the suite ran near
        // midnight (a 1-hour-ago event would fall into yesterday).
        let cal = Calendar.current
        let noon = cal.date(bySettingHour: 12, minute: 0, second: 0,
                            of: Date()) ?? Date()
        let yesterday = cal.date(byAdding: .day, value: -1, to: noon)!
        let log = SessionLog(schemaVersion: 1, events: [
            evt("yesterday", yesterday,
                yesterday.addingTimeInterval(60), 100),
            evt("morning", noon.addingTimeInterval(-3600),
                noon.addingTimeInterval(-3500), 200),
            evt("now", noon.addingTimeInterval(-60), noon, 300),
        ])
        XCTAssertEqual(log.wordsToday(now: noon), 500)
    }

    func test_wordsByDay_keysAreLocalMidnight() {
        let cal = Calendar.current
        let day1 = cal.startOfDay(for: Date(timeIntervalSince1970: 1_700_000_000))
        let day2 = cal.date(byAdding: .day, value: 1, to: day1)!
        let log = SessionLog(schemaVersion: 1, events: [
            evt("a", day1.addingTimeInterval(3600),
                day1.addingTimeInterval(7200), 100),
            evt("b", day1.addingTimeInterval(50_000),
                day1.addingTimeInterval(53_000), 200),
            evt("c", day2.addingTimeInterval(3600),
                day2.addingTimeInterval(7200), 300),
        ])
        let counts = log.wordsByDay(in: day1...day2)
        XCTAssertEqual(counts[day1], 300)
        XCTAssertEqual(counts[day2], 300)
    }

    func test_eventsRecent_limitsAndSortsDesc() {
        var events: [SessionEvent] = []
        for i in 0..<10 {
            events.append(evt(
                "e\(i)",
                Date(timeIntervalSince1970: TimeInterval(i * 100)),
                Date(timeIntervalSince1970: TimeInterval(i * 100 + 50)),
                i * 10))
        }
        let log = SessionLog(schemaVersion: 1, events: events)
        let recent = log.eventsRecent(limit: 3)
        XCTAssertEqual(recent.count, 3)
        XCTAssertEqual(recent.map(\.id), ["e9", "e8", "e7"])
    }

    func test_merge_idempotent() {
        let e1 = evt("a", Date(timeIntervalSince1970: 100),
                     Date(timeIntervalSince1970: 200), 50)
        let log = SessionLog(schemaVersion: 1, events: [e1])
        let merged = SessionLog.merged(log, log)
        XCTAssertEqual(merged.events.count, 1)
    }
}
