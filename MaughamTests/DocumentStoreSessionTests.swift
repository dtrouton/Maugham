import XCTest
@testable import Maugham

/// Session-log tests for DocumentStore. Save / autosave / conflict tests
/// migrated to DocumentTests.swift in the document-first-class refactor
/// (T11); this file retains the session-event persistence coverage.
@MainActor
final class DocumentStoreSessionTests: XCTestCase {
    var temp: TempDirectory!

    override func setUp() async throws {
        try await super.setUp()
        temp = try TempDirectory()
    }

    override func tearDown() async throws {
        temp = nil
        try await super.tearDown()
    }

    func test_appendSessionEvent_persistsToDisk() async throws {
        let url = try await ProjectFactory.createNovelProject(
            named: "Sessions", in: temp.url)
        let ds = try await DocumentStore.open(url: url)

        let event = SessionEvent(
            id: "evt-1",
            startedAt: Date(timeIntervalSince1970: 100),
            endedAt: Date(timeIntervalSince1970: 200),
            wordsNet: 50)
        try await ds.appendSessionEvent(event)

        let loaded = try await ds.loadSessionLog()
        XCTAssertEqual(loaded.events.count, 1)
        XCTAssertEqual(loaded.events[0].id, "evt-1")
        await ds.close()
    }

    func test_loadSessionLog_returnsEmptyWhenFileMissing() async throws {
        let url = try await ProjectFactory.createNovelProject(
            named: "EmptySessions", in: temp.url)
        let ds = try await DocumentStore.open(url: url)
        let log = try await ds.loadSessionLog()
        XCTAssertEqual(log, SessionLog.empty)
        await ds.close()
    }

    func test_appendSessionEvent_unionsExistingEvents() async throws {
        let url = try await ProjectFactory.createNovelProject(
            named: "MultiSessions", in: temp.url)
        let ds = try await DocumentStore.open(url: url)

        let e1 = SessionEvent(id: "a",
            startedAt: Date(timeIntervalSince1970: 100),
            endedAt: Date(timeIntervalSince1970: 200), wordsNet: 50)
        let e2 = SessionEvent(id: "b",
            startedAt: Date(timeIntervalSince1970: 300),
            endedAt: Date(timeIntervalSince1970: 400), wordsNet: 75)
        try await ds.appendSessionEvent(e1)
        try await ds.appendSessionEvent(e2)

        let loaded = try await ds.loadSessionLog()
        XCTAssertEqual(loaded.events.count, 2)
        XCTAssertEqual(loaded.events.map(\.id), ["a", "b"])
        await ds.close()
    }
}
