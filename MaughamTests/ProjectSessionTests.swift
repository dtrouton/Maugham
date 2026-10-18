import XCTest
@testable import MaughamCore
@testable import Maugham

/// **`ProjectSession`: an open project's stores and services, outside the
/// view** (foundations plan 3, Task 2).
///
/// Against a real project made by `ProjectFactory`, the way the store tests
/// make one. That `close()` detaches the roster BEFORE the DocumentStore
/// closes is a source census in `TranslatorEnvironmentTests`
/// (`test_everyWindowEndingPathShutsEverySessionDown`); this file pins what
/// opening and closing DO.
@MainActor
final class ProjectSessionTests: XCTestCase {

    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "ProjectSessionTests-\(UUID().uuidString)"
    }

    override func tearDown() {
        UserDefaults().removePersistentDomain(forName: suiteName)
        suiteName = nil
        super.tearDown()
    }

    private func openSession() async throws -> ProjectSession {
        let url = try await ProjectFactory.createNovelProject(
            named: "Session-\(UUID().uuidString.prefix(6))", in: TestTemp.root)
        let preferences = UserPreferences(defaults: try XCTUnwrap(UserDefaults(suiteName: suiteName)))
        return try await ProjectSession.open(
            url: url, preferences: preferences, liveCanvas: nil,
            onCompilerFlash: { _ in })
    }

    // (a)
    func test_openCrossLinksTheTwoStores() async throws {
        let session = try await openSession()
        XCTAssertTrue(session.documentStore.projectStore === session.projectStore,
                      "the DocumentStore must reach the session's ProjectStore — the "
                      + "schema gate at the first narrowing writes through it")
        XCTAssertTrue(session.projectStore.documentStore === session.documentStore,
                      "the ProjectStore must reach the session's DocumentStore")
        await session.close()
    }

    // (b)
    func test_openWiresEveryServiceAndCloseDetachesThemAll() async throws {
        let session = try await openSession()
        let roster = session.roster
        XCTAssertNotNil(roster.compiler.configuredModel, "premise: open wired the compiler")
        XCTAssertNotNil(roster.translator.configuredModel, "premise: open wired the translator")
        XCTAssertNotNil(roster.designer.configuredModel, "premise: open wired the designer")
        XCTAssertNotNil(roster.pipeline.configuredModel, "premise: open wired the pipeline")

        await session.close()

        XCTAssertNil(roster.compiler.configuredModel, "the compiler is unwired")
        XCTAssertNil(roster.translator.configuredModel, "the translator is unwired")
        XCTAssertNil(roster.designer.configuredModel, "the designer is unwired")
        XCTAssertNil(roster.pipeline.configuredModel, "the pipeline is unwired")
        let refused = await roster.coldCall.call(message: "x", preamble: nil, model: "m")
        XCTAssertEqual(refused, .failed(.sessionDied(detail: ColdCall.notWiredDetail)),
                       "the cold-call runner forgot the window's factory")
    }

    // (c)
    func test_aClosedSessionIsReleasedWithItsLastReference() async throws {
        weak var released: ProjectSession?
        do {
            let session = try await openSession()
            released = session
            await session.close()
        }
        XCTAssertNil(released, "nothing the session wired may keep it alive once it is "
                     + "closed and its owner lets go")
    }
}
