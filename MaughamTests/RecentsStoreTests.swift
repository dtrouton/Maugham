import XCTest
@testable import Maugham

@MainActor
final class RecentsStoreTests: XCTestCase {
    var defaults: UserDefaults!
    var store: RecentsStore!

    override func setUp() async throws {
        try await super.setUp()
        let suite = "RecentsStoreTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        store = RecentsStore(defaults: defaults)
    }

    override func tearDown() async throws {
        defaults = nil
        store = nil
        try await super.tearDown()
    }

    func test_emptyByDefault() {
        XCTAssertTrue(store.recents.isEmpty)
    }

    func test_record_addsURLToFront() {
        let a = URL(fileURLWithPath: "/tmp/A")
        let b = URL(fileURLWithPath: "/tmp/B")
        store.record(a)
        store.record(b)
        XCTAssertEqual(store.recents.map(\.path), ["/tmp/B", "/tmp/A"])
    }

    func test_record_dedupesAndPromotes() {
        let a = URL(fileURLWithPath: "/tmp/A")
        let b = URL(fileURLWithPath: "/tmp/B")
        store.record(a)
        store.record(b)
        store.record(a) // should move A to front, not duplicate
        XCTAssertEqual(store.recents.map(\.path), ["/tmp/A", "/tmp/B"])
    }

    func test_record_capsAtTen() {
        for i in 0..<15 {
            store.record(URL(fileURLWithPath: "/tmp/proj-\(i)"))
        }
        XCTAssertEqual(store.recents.count, 10)
        // Most recent first
        XCTAssertEqual(store.recents.first?.path, "/tmp/proj-14")
    }

    func test_remove_deletesByURL() {
        let a = URL(fileURLWithPath: "/tmp/A")
        let b = URL(fileURLWithPath: "/tmp/B")
        store.record(a)
        store.record(b)
        store.remove(a)
        XCTAssertEqual(store.recents.map(\.path), ["/tmp/B"])
    }

    func test_persistsAcrossInstances() {
        store.record(URL(fileURLWithPath: "/tmp/X"))
        let other = RecentsStore(defaults: defaults)
        XCTAssertEqual(other.recents.map(\.path), ["/tmp/X"])
    }
}
