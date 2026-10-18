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
        return try await ProjectSession.open(url: url)
    }

    private func preferences() throws -> UserPreferences {
        UserPreferences(defaults: try XCTUnwrap(UserDefaults(suiteName: suiteName)))
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

    // (b) — Task 3b: open is the stores; a WINDOW attaching wires the
    // services, and either its detach or the close unwires them.
    func test_openWiresNothingAndAttachingAWindowWiresEveryService() async throws {
        let session = try await openSession()
        let roster = session.roster
        XCTAssertNil(roster.compiler.configuredModel, "open alone must wire no service")
        XCTAssertNil(roster.translator.configuredModel, "open alone must wire no service")
        XCTAssertNil(roster.designer.configuredModel, "open alone must wire no service")
        XCTAssertNil(roster.pipeline.configuredModel, "open alone must wire no service")
        XCTAssertNil(session.attachment)

        let canvas = CanvasModel()
        let token = session.attachWindow(canvas: canvas, flash: { _ in },
                                         preferences: try preferences())
        XCTAssertEqual(session.attachment, token)
        XCTAssertTrue(session.projectStore.liveCanvas === canvas)
        XCTAssertNotNil(roster.compiler.configuredModel, "attaching wired the compiler")
        XCTAssertNotNil(roster.translator.configuredModel, "attaching wired the translator")
        XCTAssertNotNil(roster.designer.configuredModel, "attaching wired the designer")
        XCTAssertNotNil(roster.pipeline.configuredModel, "attaching wired the pipeline")

        session.detachWindow(token)
        XCTAssertNil(session.attachment)
        XCTAssertNil(session.projectStore.liveCanvas, "a detached window's canvas is not live")
        XCTAssertNil(roster.compiler.configuredModel, "detaching unwired the compiler")
        XCTAssertNil(roster.pipeline.configuredModel, "detaching unwired the pipeline")
        await session.close()
    }

    /// A stale attachment — a newer window attached since — detaches nothing.
    func test_aStaleAttachmentDetachesNothing() async throws {
        let session = try await openSession()
        let older = session.attachWindow(canvas: CanvasModel(), flash: { _ in },
                                         preferences: try preferences())
        let newerCanvas = CanvasModel()
        let newer = session.attachWindow(canvas: newerCanvas, flash: { _ in },
                                         preferences: try preferences())
        session.detachWindow(older)
        XCTAssertEqual(session.attachment, newer)
        XCTAssertTrue(session.projectStore.liveCanvas === newerCanvas)
        XCTAssertNotNil(session.roster.compiler.configuredModel)
        session.detachWindow(newer)
        await session.close()
    }

    // (b') close unwires an attached session's services too.
    func test_closeDetachesEveryServiceOfAnAttachedSession() async throws {
        let session = try await openSession()
        let roster = session.roster
        session.attachWindow(canvas: CanvasModel(), flash: { _ in },
                             preferences: try preferences())
        XCTAssertNotNil(roster.compiler.configuredModel, "premise: the window wired the compiler")

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
        let giveBackPrevious = try XCTUnwrap(load.range(of: "await sessions.release(previous)"),
                                             "load() must await the previous project's release")
        let acquire = try XCTUnwrap(load.range(of: "sessions.acquire("),
                                    "load() must borrow its session from the registry")
        // …as a WINDOW (Task 3b): the borrow that attaches this window's
        // canvas and flash and configures the services. A reader borrow here
        // would leave the window with no services and its canvas not live.
        XCTAssertTrue(load.contains("sessions.acquire(url, as: .window(attach:"),
                      "load() must borrow as a window")
        XCTAssertTrue(load.contains("session.attachWindow("),
                      "load()'s window borrow must attach the window to the session")
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
        // A borrow this window will not keep (another run of load() already
        // adopted one, or the load was cancelled on a window known to be
        // gone) goes back before the adoption. A cancelled load on a LIVE
        // window keeps it (Task 3b): nothing promises the task re-runs.
        let unkept = try XCTUnwrap(load.range(of: """
            if self.lease != nil
                            || (Task.isCancelled && window != nil && !MaughamEvent.isLive(window)) {
            """), "load() must check whether it can keep the borrow")
        let adopt = try XCTUnwrap(load.range(of: "self.lease = lease"),
                                  "load() never adopts the borrow")
        XCTAssertTrue(acquire.upperBound < unkept.lowerBound && unkept.upperBound < adopt.lowerBound,
                      "the keep-check sits between the acquire and the adoption")
        let between = load[unkept.upperBound..<adopt.lowerBound]
        XCTAssertTrue(between.contains("await sessions.release(lease)"),
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
