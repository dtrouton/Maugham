import XCTest
@testable import MaughamCore
@testable import Maugham

/// **`ProjectSessionRegistry`: one session per project, reference-counted**
/// (foundations plan 3, Task 3).
///
/// Against real projects made by `ProjectFactory` and real
/// `ProjectSession.open`s, because what the registry protects is exactly the
/// open's side effects — a second `DocumentStore.open` on one folder. The
/// `open` closure counts how many times it ran.
@MainActor
final class ProjectSessionRegistryTests: XCTestCase {

    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "ProjectSessionRegistryTests-\(UUID().uuidString)"
    }

    override func tearDown() {
        UserDefaults().removePersistentDomain(forName: suiteName)
        suiteName = nil
        super.tearDown()
    }

    /// How many times an `open` closure ran.
    @MainActor
    private final class Opens {
        var count = 0
    }

    private struct PlannedFailure: Error {}

    private func makeProject() async throws -> URL {
        try await ProjectFactory.createNovelProject(
            named: "Registry-\(UUID().uuidString.prefix(6))", in: TestTemp.root)
    }

    /// An `open` for `url` that counts itself, yielding first so a concurrent
    /// caller has the chance to arrive while it is in flight.
    private func opener(_ url: URL, counting opens: Opens)
        -> @MainActor () async throws -> ProjectSession {
        let suiteName = self.suiteName!
        return {
            opens.count += 1
            await Task.yield()
            let preferences = UserPreferences(
                defaults: try XCTUnwrap(UserDefaults(suiteName: suiteName)))
            return try await ProjectSession.open(
                url: url, preferences: preferences, liveCanvas: nil,
                onCompilerFlash: { _ in })
        }
    }

    // (a)
    func test_twoAcquiresForOneProjectShareOneSessionAndOpenOnce() async throws {
        let url = try await makeProject()
        let registry = ProjectSessionRegistry()
        let opens = Opens()

        let first = try await registry.acquire(url, open: opener(url, counting: opens))
        let second = try await registry.acquire(url, open: opener(url, counting: opens))

        XCTAssertTrue(first === second, "a second window must borrow the live session")
        XCTAssertEqual(opens.count, 1, "the project was opened twice")
        XCTAssertEqual(registry.openCount, 1)

        await registry.release(url)
        await registry.release(url)
        XCTAssertEqual(registry.openCount, 0)
    }

    /// The key is the folder, not the URL's spelling: a trailing slash and a
    /// `..` detour name the same project.
    func test_spellingsOfOneFolderAreOneProject() async throws {
        let url = try await makeProject()
        let registry = ProjectSessionRegistry()
        let opens = Opens()
        let detour = url.appendingPathComponent("..", isDirectory: true)
            .appendingPathComponent(url.lastPathComponent, isDirectory: true)

        let first = try await registry.acquire(url, open: opener(url, counting: opens))
        let second = try await registry.acquire(detour, open: opener(url, counting: opens))

        XCTAssertTrue(first === second)
        XCTAssertEqual(opens.count, 1)
        await registry.release(detour)
        await registry.release(url)
        XCTAssertEqual(registry.openCount, 0)
    }

    // (b)
    func test_concurrentAcquiresAwaitTheSameOpen() async throws {
        let url = try await makeProject()
        let registry = ProjectSessionRegistry()
        let opens = Opens()

        async let a = registry.acquire(url, open: opener(url, counting: opens))
        async let b = registry.acquire(url, open: opener(url, counting: opens))
        let (first, second) = try await (a, b)

        XCTAssertTrue(first === second)
        XCTAssertEqual(opens.count, 1, "two concurrent acquires opened the project twice")
        XCTAssertEqual(registry.openCount, 1)

        await registry.release(url)
        await registry.release(url)
        XCTAssertEqual(registry.openCount, 0)
    }

    // (c)
    func test_theLastReleaseClosesTheSession() async throws {
        let url = try await makeProject()
        let registry = ProjectSessionRegistry()
        let opens = Opens()
        let session = try await registry.acquire(url, open: opener(url, counting: opens))
        _ = try await registry.acquire(url, open: opener(url, counting: opens))
        let roster = session.roster
        XCTAssertNotNil(roster.compiler.configuredModel, "premise: the session is wired")

        await registry.release(url)
        XCTAssertEqual(registry.openCount, 1, "one borrow is still out")
        XCTAssertNotNil(roster.compiler.configuredModel,
                        "a release that is not the last closed a session another window holds")

        await registry.release(url)
        XCTAssertEqual(registry.openCount, 0)
        XCTAssertNil(roster.compiler.configuredModel,
                     "the last release must run close() — the roster detaches")
    }

    // (d)
    func test_afterTheLastReleaseNothingKeepsTheSessionAlive() async throws {
        let url = try await makeProject()
        let registry = ProjectSessionRegistry()
        let opens = Opens()
        weak var released: ProjectSession?
        do {
            let session = try await registry.acquire(url, open: opener(url, counting: opens))
            released = session
        }
        await registry.release(url)
        XCTAssertNil(released, "the registry kept a closed session alive")
    }

    // (e)
    func test_aDifferentProjectOpensItsOwnSession() async throws {
        let one = try await makeProject()
        let two = try await makeProject()
        let registry = ProjectSessionRegistry()
        let opens = Opens()

        let first = try await registry.acquire(one, open: opener(one, counting: opens))
        let second = try await registry.acquire(two, open: opener(two, counting: opens))

        XCTAssertFalse(first === second)
        XCTAssertEqual(opens.count, 2)
        XCTAssertEqual(registry.openCount, 2)

        await registry.release(one)
        XCTAssertEqual(registry.openCount, 1, "releasing one project closed the other")
        await registry.release(two)
        XCTAssertEqual(registry.openCount, 0)
    }

    // (f)
    func test_aFailedOpenRegistersNothingAndTheNextAcquireRetries() async throws {
        let url = try await makeProject()
        let registry = ProjectSessionRegistry()
        let opens = Opens()

        do {
            _ = try await registry.acquire(url) {
                opens.count += 1
                throw PlannedFailure()
            }
            XCTFail("the failed open must reach the caller")
        } catch is PlannedFailure {}
        XCTAssertEqual(registry.openCount, 0, "a failed open left a session registered")

        _ = try await registry.acquire(url, open: opener(url, counting: opens))
        XCTAssertEqual(opens.count, 2, "the next acquire must open afresh")
        XCTAssertEqual(registry.openCount, 1)
        await registry.release(url)
    }

    /// An unbalanced release — nothing borrowed — changes nothing.
    func test_aReleaseWithNothingBorrowedIsANoOp() async throws {
        let url = try await makeProject()
        let registry = ProjectSessionRegistry()
        await registry.release(url)
        XCTAssertEqual(registry.openCount, 0)
    }
}
