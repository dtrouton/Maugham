import XCTest
@testable import MaughamCore
@testable import Maugham

/// **`ProjectSessionRegistry`: one session per project, reference-counted**
/// (foundations plan 3, Task 3) — **and two kinds of borrow** (Task 3b).
///
/// Against real projects made by `ProjectFactory` and real
/// `ProjectSession.open`s, because what the registry protects is exactly the
/// open's side effects — a second `DocumentStore.open` on one folder. The
/// `open` closure counts how many times it ran.
///
/// Task 3b's half: a WINDOW borrow attaches its window (the canvas seam, the
/// flash, the services) and the newest wins; a READER borrow holds only the
/// stores. The two hazards it closes are pinned by scenario: a window
/// reopened on a project a reader kept open must be the live canvas and the
/// flash's target, and the last window going must end every `claude` service
/// even while a reader holds the stores.
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

    /// A stand-in for a project window: its own canvas model, and the flashes
    /// that reached it.
    @MainActor
    private final class FakeWindow {
        let canvas = CanvasModel()
        var flashes: [CompilerOrchestrator.Acknowledgment] = []
    }

    private struct PlannedFailure: Error {}

    private func makeProject() async throws -> URL {
        try await ProjectFactory.createNovelProject(
            named: "Registry-\(UUID().uuidString.prefix(6))", in: TestTemp.root)
    }

    private func preferences() throws -> UserPreferences {
        UserPreferences(defaults: try XCTUnwrap(UserDefaults(suiteName: suiteName)))
    }

    /// An `open` for `url` that counts itself, yielding first so a concurrent
    /// caller has the chance to arrive while it is in flight.
    private func opener(_ url: URL, counting opens: Opens)
        -> @MainActor () async throws -> ProjectSession {
        return {
            opens.count += 1
            await Task.yield()
            return try await ProjectSession.open(url: url)
        }
    }

    /// A window borrow for `window`, attached exactly as `ProjectWindow.load`
    /// attaches one.
    private func windowBorrow(_ window: FakeWindow) throws -> ProjectSessionRegistry.Borrow {
        let preferences = try preferences()
        return .window(attach: { session in
            session.attachWindow(canvas: window.canvas,
                                 flash: { window.flashes.append($0) },
                                 preferences: preferences)
        })
    }

    /// Opens the project's first chapter in the session's `DocumentStore`, so
    /// the compiler has a reading to act on.
    private func openFirstChapter(in session: ProjectSession) async throws -> String {
        let item = try XCTUnwrap(session.projectStore.manifest.structure.first)
        let document = try await Document.load(
            url: session.url.appendingPathComponent(item.path ?? ""),
            device: "test-mac", session: "s", presenter: nil)
        session.documentStore.register(document: document, for: item.path ?? "")
        return document.docId
    }

    /// Presses Run round on a piece with no stage: the configured compiler's
    /// only answer is `.noEditor`, through its production `onRunAcknowledged`
    /// — so whoever receives it is whoever the session's flash reaches.
    private func pressRound(_ session: ProjectSession, docId: String) {
        session.roster.compiler.runRequested(docId: docId, kind: .round)
    }

    private func assertWired(_ roster: AgentRoster, _ message: String,
                             file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertNotNil(roster.compiler.configuredModel, "compiler: \(message)", file: file, line: line)
        XCTAssertNotNil(roster.translator.configuredModel, "translator: \(message)", file: file, line: line)
        XCTAssertNotNil(roster.designer.configuredModel, "designer: \(message)", file: file, line: line)
        XCTAssertNotNil(roster.pipeline.configuredModel, "pipeline: \(message)", file: file, line: line)
    }

    private func assertUnwired(_ roster: AgentRoster, _ message: String,
                               file: StaticString = #filePath, line: UInt = #line) async {
        XCTAssertNil(roster.compiler.configuredModel, "compiler: \(message)", file: file, line: line)
        XCTAssertNil(roster.translator.configuredModel, "translator: \(message)", file: file, line: line)
        XCTAssertNil(roster.designer.configuredModel, "designer: \(message)", file: file, line: line)
        XCTAssertNil(roster.pipeline.configuredModel, "pipeline: \(message)", file: file, line: line)
        let refused = await roster.coldCall.call(message: "x", preamble: nil, model: "m")
        XCTAssertEqual(refused, .failed(.sessionDied(detail: ColdCall.notWiredDetail)),
                       "coldCall: \(message)", file: file, line: line)
    }

    // MARK: - One session per project (Task 3)

    func test_twoAcquiresForOneProjectShareOneSessionAndOpenOnce() async throws {
        let url = try await makeProject()
        let registry = ProjectSessionRegistry()
        let opens = Opens()

        let first = try await registry.acquire(url, as: .reader, open: opener(url, counting: opens))
        let second = try await registry.acquire(url, as: .reader, open: opener(url, counting: opens))

        XCTAssertTrue(first.session === second.session, "a second borrower must share the live session")
        XCTAssertEqual(opens.count, 1, "the project was opened twice")
        XCTAssertEqual(registry.openCount, 1)

        await registry.release(first)
        await registry.release(second)
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

        let first = try await registry.acquire(url, as: .reader, open: opener(url, counting: opens))
        let second = try await registry.acquire(detour, as: .reader, open: opener(url, counting: opens))

        XCTAssertTrue(first.session === second.session)
        XCTAssertEqual(opens.count, 1)
        await registry.release(second)
        await registry.release(first)
        XCTAssertEqual(registry.openCount, 0)
    }

    func test_concurrentAcquiresAwaitTheSameOpen() async throws {
        let url = try await makeProject()
        let registry = ProjectSessionRegistry()
        let opens = Opens()

        async let a = registry.acquire(url, as: .reader, open: opener(url, counting: opens))
        async let b = registry.acquire(url, as: .reader, open: opener(url, counting: opens))
        let (first, second) = try await (a, b)

        XCTAssertTrue(first.session === second.session)
        XCTAssertEqual(opens.count, 1, "two concurrent acquires opened the project twice")
        XCTAssertEqual(registry.openCount, 1)

        await registry.release(first)
        await registry.release(second)
        XCTAssertEqual(registry.openCount, 0)
    }

    func test_theLastReleaseClosesTheSession() async throws {
        let url = try await makeProject()
        let registry = ProjectSessionRegistry()
        let opens = Opens()
        let first = try await registry.acquire(url, as: .reader, open: opener(url, counting: opens))
        let second = try await registry.acquire(url, as: .reader, open: opener(url, counting: opens))
        let documentStore = first.session.documentStore
        XCTAssertNotNil(documentStore.presenter, "premise: the stores are open")

        await registry.release(first)
        XCTAssertEqual(registry.openCount, 1, "one borrow is still out")
        XCTAssertNotNil(documentStore.presenter,
                        "a release that is not the last closed a session another borrower holds")

        await registry.release(second)
        XCTAssertEqual(registry.openCount, 0)
        XCTAssertNil(documentStore.presenter,
                     "the last release must run close() — the DocumentStore drains")
    }

    func test_afterTheLastReleaseNothingKeepsTheSessionAlive() async throws {
        let url = try await makeProject()
        let registry = ProjectSessionRegistry()
        let opens = Opens()
        let window = FakeWindow()
        weak var released: ProjectSession?
        do {
            let lease = try await registry.acquire(url, as: try windowBorrow(window),
                                                   open: opener(url, counting: opens))
            released = lease.session
            await registry.release(lease)
        }
        XCTAssertNil(released, "the registry kept a closed session alive")
    }

    func test_aDifferentProjectOpensItsOwnSession() async throws {
        let one = try await makeProject()
        let two = try await makeProject()
        let registry = ProjectSessionRegistry()
        let opens = Opens()

        let first = try await registry.acquire(one, as: .reader, open: opener(one, counting: opens))
        let second = try await registry.acquire(two, as: .reader, open: opener(two, counting: opens))

        XCTAssertFalse(first.session === second.session)
        XCTAssertEqual(opens.count, 2)
        XCTAssertEqual(registry.openCount, 2)

        await registry.release(first)
        XCTAssertEqual(registry.openCount, 1, "releasing one project closed the other")
        await registry.release(second)
        XCTAssertEqual(registry.openCount, 0)
    }

    func test_aFailedOpenRegistersNothingAndTheNextAcquireRetries() async throws {
        let url = try await makeProject()
        let registry = ProjectSessionRegistry()
        let opens = Opens()

        do {
            _ = try await registry.acquire(url, as: .reader) {
                opens.count += 1
                throw PlannedFailure()
            }
            XCTFail("the failed open must reach the caller")
        } catch is PlannedFailure {}
        XCTAssertEqual(registry.openCount, 0, "a failed open left a session registered")

        let lease = try await registry.acquire(url, as: .reader, open: opener(url, counting: opens))
        XCTAssertEqual(opens.count, 2, "the next acquire must open afresh")
        XCTAssertEqual(registry.openCount, 1)
        await registry.release(lease)
    }

    /// A lease given back twice — the second time with nothing borrowed —
    /// changes nothing, and in particular does not close a session somebody
    /// else holds.
    func test_aLeaseGivenBackTwiceIsANoOpTheSecondTime() async throws {
        let url = try await makeProject()
        let registry = ProjectSessionRegistry()
        let opens = Opens()
        let first = try await registry.acquire(url, as: .reader, open: opener(url, counting: opens))
        let second = try await registry.acquire(url, as: .reader, open: opener(url, counting: opens))

        await registry.release(first)
        await registry.release(first)
        XCTAssertEqual(registry.openCount, 1, "a double release counted as the other borrower's")
        await registry.release(second)
        XCTAssertEqual(registry.openCount, 0)
    }

    // MARK: - Window borrows and reader borrows (Task 3b)

    /// (a) A reader holds the stores and nothing that bills; the window that
    /// borrows after it is the one attached.
    func test_aReaderBorrowsOnlyTheStoresAndAWindowAfterItIsAttached() async throws {
        let url = try await makeProject()
        let registry = ProjectSessionRegistry()
        let opens = Opens()
        let window = FakeWindow()

        let reader = try await registry.acquire(url, as: .reader, open: opener(url, counting: opens))
        let session = reader.session
        await assertUnwired(session.roster, "a reader alone must configure no service")
        XCTAssertNil(session.projectStore.liveCanvas, "a reader has no canvas to install")

        let lease = try await registry.acquire(url, as: try windowBorrow(window),
                                               open: opener(url, counting: opens))
        XCTAssertTrue(lease.session === session)
        XCTAssertEqual(opens.count, 1)
        XCTAssertTrue(session.projectStore.liveCanvas === window.canvas,
                      "the window's canvas must be the live one, or Claude's cards go to "
                      + "the sidecar behind it")
        assertWired(session.roster, "the window borrow must configure every service")
        let docId = try await openFirstChapter(in: session)
        pressRound(session, docId: docId)
        XCTAssertEqual(window.flashes, [.noEditor], "the compiler's flash must reach the window")

        await registry.release(lease)
        await registry.release(reader)
    }

    /// **(b)–(d), the two hazards end to end.** A window, then a reader; the
    /// window closes; a new window opens on the project the reader kept open;
    /// the reader goes last.
    func test_theServicesFollowTheWindowsAndTheStoresFollowTheBorrows() async throws {
        let url = try await makeProject()
        let registry = ProjectSessionRegistry()
        let opens = Opens()
        let windowA = FakeWindow()
        let windowB = FakeWindow()
        weak var weakSession: ProjectSession?

        do {
            let leaseA = try await registry.acquire(url, as: try windowBorrow(windowA),
                                                    open: opener(url, counting: opens))
            let reader = try await registry.acquire(url, as: .reader,
                                                    open: opener(url, counting: opens))
            let session = leaseA.session
            weakSession = session
            let roster = session.roster
            let docId = try await openFirstChapter(in: session)
            assertWired(roster, "premise: window A is attached")

            // (b) The last WINDOW goes while a reader holds the stores.
            await registry.release(leaseA)
            await assertUnwired(roster, "the last window closing must end every service, "
                                + "even while a reader holds the session")
            XCTAssertNil(session.projectStore.liveCanvas,
                         "a closed window's canvas must not stay the live one")
            XCTAssertNotNil(session.documentStore.presenter,
                            "the reader still holds the stores — they must stay open")
            XCTAssertEqual(registry.openCount, 1)

            // (c) A window reopens on the project the reader kept open.
            let leaseB = try await registry.acquire(url, as: try windowBorrow(windowB),
                                                    open: opener(url, counting: opens))
            XCTAssertTrue(leaseB.session === session, "the reader's session is borrowed, not reopened")
            XCTAssertEqual(opens.count, 1)
            XCTAssertTrue(session.projectStore.liveCanvas === windowB.canvas,
                          "the reopened window's canvas must be the live one")
            assertWired(roster, "the reopened window must configure the services again")
            pressRound(session, docId: docId)
            XCTAssertEqual(windowB.flashes, [.noEditor], "the flash must reach the reopened window")
            XCTAssertEqual(windowA.flashes, [], "…and never the closed one")

            await registry.release(leaseB)
            await assertUnwired(roster, "window B closing ends the services too")

            // (d) The reader goes last: the stores close.
            let documentStore = session.documentStore
            await registry.release(reader)
            XCTAssertNil(documentStore.presenter, "the last borrow must run close()")
            XCTAssertEqual(registry.openCount, 0)
        }
        XCTAssertNil(weakSession, "nothing may keep the closed session alive")
    }

    /// (e) Two windows on one project: the newer is attached, and the OLDER
    /// going back leaves the newer's attachment alone.
    func test_releasingTheOlderWindowLeavesTheNewerAttached() async throws {
        let url = try await makeProject()
        let registry = ProjectSessionRegistry()
        let opens = Opens()
        let older = FakeWindow()
        let newer = FakeWindow()

        let leaseOld = try await registry.acquire(url, as: try windowBorrow(older),
                                                  open: opener(url, counting: opens))
        let leaseNew = try await registry.acquire(url, as: try windowBorrow(newer),
                                                  open: opener(url, counting: opens))
        let session = leaseNew.session
        XCTAssertTrue(session.projectStore.liveCanvas === newer.canvas, "the newest window wins")

        await registry.release(leaseOld)
        XCTAssertTrue(session.projectStore.liveCanvas === newer.canvas,
                      "a stale window's release detached the newer one")
        assertWired(session.roster, "a stale window's release must not detach the services")
        let docId = try await openFirstChapter(in: session)
        pressRound(session, docId: docId)
        XCTAssertEqual(newer.flashes, [.noEditor])
        XCTAssertEqual(older.flashes, [])

        await registry.release(leaseNew)
    }

    /// …and the NEWER going back first hands the attachment to the older
    /// window, which is still open: a live window must never be left with no
    /// services and a canvas that is not the live one.
    func test_releasingTheAttachedWindowReattachesTheOlderOne() async throws {
        let url = try await makeProject()
        let registry = ProjectSessionRegistry()
        let opens = Opens()
        let older = FakeWindow()
        let newer = FakeWindow()

        let leaseOld = try await registry.acquire(url, as: try windowBorrow(older),
                                                  open: opener(url, counting: opens))
        let leaseNew = try await registry.acquire(url, as: try windowBorrow(newer),
                                                  open: opener(url, counting: opens))
        let session = leaseOld.session

        await registry.release(leaseNew)
        XCTAssertTrue(session.projectStore.liveCanvas === older.canvas,
                      "the window still open must take the attachment back")
        assertWired(session.roster, "an open window must keep its services")
        let docId = try await openFirstChapter(in: session)
        pressRound(session, docId: docId)
        XCTAssertEqual(older.flashes, [.noEditor])
        XCTAssertEqual(newer.flashes, [])

        await registry.release(leaseOld)
    }

    /// (f) MCP follows the WINDOW borrows: announced while one is out, and
    /// forgotten when the last goes back even though a reader remains.
    func test_mcpRegistrationFollowsTheWindowBorrows() async throws {
        let url = try await makeProject()
        let mcp = ProjectRegistry()
        let registry = ProjectSessionRegistry(mcp: mcp)
        let opens = Opens()
        let id = ProjectIdentifier.id(for: url)

        let reader = try await registry.acquire(url, as: .reader, open: opener(url, counting: opens))
        XCTAssertNil(mcp.lookup(id: id), "a reader alone must not announce the project")

        let one = try await registry.acquire(url, as: try windowBorrow(FakeWindow()),
                                             open: opener(url, counting: opens))
        XCTAssertTrue(mcp.lookup(id: id)?.store === reader.session.projectStore,
                      "a window borrow must announce the session's store")
        let two = try await registry.acquire(url, as: try windowBorrow(FakeWindow()),
                                             open: opener(url, counting: opens))

        await registry.release(one)
        XCTAssertNotNil(mcp.lookup(id: id), "a window is still open on the project")
        await registry.release(two)
        XCTAssertNil(mcp.lookup(id: id),
                     "the last window going must unregister the project, reader or no reader")

        await registry.release(reader)
        XCTAssertNil(mcp.lookup(id: id))
    }

    /// (g) An acquire that arrives while the last release's close is still
    /// running gets a FRESH session, never the one being torn down.
    func test_anAcquireDuringTheLastCloseOpensAFreshSession() async throws {
        let url = try await makeProject()
        let registry = ProjectSessionRegistry()
        let opens = Opens()
        let lease = try await registry.acquire(url, as: .reader, open: opener(url, counting: opens))
        let closing = lease.session
        let reopen = opener(url, counting: opens)

        // Main-actor tasks start in the order they are made: the release runs
        // to its `await` on the close (with the close registered), and only
        // then does the acquire run and find the close in flight.
        let releasing = Task { await registry.release(lease) }
        let reacquiring = Task { try await registry.acquire(url, as: .reader, open: reopen) }
        await releasing.value
        let fresh = try await reacquiring.value

        XCTAssertFalse(fresh.session === closing, "an acquire borrowed a session being closed")
        XCTAssertEqual(opens.count, 2, "the acquire must open afresh after the close")
        XCTAssertNil(closing.documentStore.presenter, "premise: the old session closed")
        XCTAssertEqual(registry.openCount, 1)
        await registry.release(fresh)
    }
}
