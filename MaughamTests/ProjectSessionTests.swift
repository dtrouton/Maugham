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

    // The window's load decision: a re-run for the SAME project opens
    // nothing new; another project's session closes before the open.
    func test_aReRunForTheSameProjectReusesTheLiveSession() {
        let a = TestTemp.root.appendingPathComponent("A", isDirectory: true)
        let b = TestTemp.root.appendingPathComponent("B", isDirectory: true)
        XCTAssertEqual(ProjectSession.loadStep(live: a, requested: a), .reuseLive)
        XCTAssertEqual(ProjectSession.loadStep(live: a, requested: b), .closeLiveThenOpen)
        XCTAssertEqual(ProjectSession.loadStep(live: nil, requested: a), .open)
    }

    /// …and the window's `load()` acts on it, borrowing through the registry
    /// (Task 3): it asks the decision, gives the previous project's borrow
    /// back (AWAITED) before it acquires, opens through `ProjectSession`
    /// inside that ONE acquire, and gives back a borrow it will not keep
    /// before it adopts one.
    func test_theWindowsLoadAsksTheDecisionAndClosesBeforeItOpens() throws {
        // The WINDOW's `load()` — several other windows declare one too.
        let masked = SourceTree.mask(try SourceTree.windowSource())
        let text = String(decoding: masked, as: UTF8.self)
        let header = try XCTUnwrap(text.range(of: "private func load() async {"),
                                   "ProjectWindow declares no load()")
        let start = text.utf8.distance(from: text.startIndex, to: header.lowerBound)
        let end = try XCTUnwrap(SourceTree.bodyEnd(in: masked, from: start))
        let load = String(decoding: masked[start...end], as: UTF8.self)
        let ask = try XCTUnwrap(load.range(of: "ProjectSession.loadStep("),
                                "load() must ask the reuse/close decision")
        let giveBackPrevious = try XCTUnwrap(load.range(of: "await sessions.release(previous.url)"),
                                             "load() must await the previous project's release")
        let acquire = try XCTUnwrap(load.range(of: "sessions.acquire("),
                                    "load() must borrow its session from the registry")
        let open = try XCTUnwrap(load.range(of: "ProjectSession.open("),
                                 "load() must open through ProjectSession")
        XCTAssertTrue(ask.lowerBound < giveBackPrevious.lowerBound
                      && giveBackPrevious.lowerBound < acquire.lowerBound
                      && acquire.lowerBound < open.lowerBound,
                      "the decision, then the release, then the acquire that opens — in that order")
        XCTAssertEqual(load.components(separatedBy: "sessions.acquire(").count - 1, 1,
                       "load() acquires in exactly one place — a second acquire (the "
                       + "reuse arm included) is a borrow nobody gives back")
        XCTAssertEqual(load.components(separatedBy: "ProjectSession.open(").count - 1, 1,
                       "load() opens only inside the registry's acquire")
        XCTAssertFalse(load.contains(".close()"),
                       "load() closes a session it only borrowed — give it back instead")
        // A borrow this window will not keep (cancelled, or another run of
        // load() already adopted one) goes back before the adoption.
        let unkept = try XCTUnwrap(load.range(of: "if Task.isCancelled || self.session != nil {"),
                                   "load() must check whether it can keep the borrow")
        let adopt = try XCTUnwrap(load.range(of: "self.session = session"),
                                  "load() never adopts the session")
        XCTAssertTrue(acquire.upperBound < unkept.lowerBound && unkept.upperBound < adopt.lowerBound,
                      "the keep-check sits between the acquire and the adoption")
        let between = load[unkept.upperBound..<adopt.lowerBound]
        XCTAssertTrue(between.contains("await sessions.release(url)"),
                      "an unkept borrow must be released")
        XCTAssertEqual(between.components(separatedBy: "await").count - 1, 1,
                       "nothing may suspend between the keep-check and the adoption "
                       + "except the unkept borrow's own release")
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
