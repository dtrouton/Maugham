import XCTest
@testable import MaughamCore
@testable import Maugham

/// **The Statistics window borrows the project's session as a READER**
/// (foundations plan 3, Task 4).
///
/// The defect: `ProjectStatisticsWindow.load()` opened a second
/// `DocumentStore` and held it only through the `weak`
/// `ProjectStore.documentStore`, so it was released at once — every
/// session-log reload returned early — and every open of the window repeated
/// the open-time registry acts. Pinned through `ProjectStatisticsSource`, the
/// window's data source, against real projects and a real registry, with no
/// window.
@MainActor
final class ProjectStatisticsWindowSessionTests: XCTestCase {

    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "ProjectStatisticsWindowSessionTests-\(UUID().uuidString)"
    }

    override func tearDown() {
        UserDefaults().removePersistentDomain(forName: suiteName)
        suiteName = nil
        super.tearDown()
    }

    private func makeProject() async throws -> URL {
        try await ProjectFactory.createNovelProject(
            named: "Stats-\(UUID().uuidString.prefix(6))", in: TestTemp.root)
    }

    /// A window borrow, attached exactly as `ProjectWindow.load` attaches one.
    private func windowBorrow() throws -> ProjectSessionRegistry.Borrow {
        let preferences = UserPreferences(
            defaults: try XCTUnwrap(UserDefaults(suiteName: suiteName)))
        let canvas = CanvasModel()
        return .window(attach: { session in
            session.attachWindow(canvas: canvas, flash: { _ in }, preferences: preferences)
        }, isLive: { true })
    }

    private func openWindow(_ url: URL, in registry: ProjectSessionRegistry) async throws
        -> ProjectSessionRegistry.Lease {
        try await registry.acquire(url, as: try windowBorrow()) {
            try await ProjectSession.open(url: url)
        }
    }

    /// (a) With a project window open, Statistics opens nothing: it borrows
    /// the window's session, and its store's `DocumentStore` is alive.
    /// Failed before the fix — the store was a fresh one whose
    /// `documentStore` was already nil.
    func test_withAWindowSessionOpen_statisticsOpensNothingAndItsStoreHasALiveDocumentStore() async throws {
        let url = try await makeProject()
        let registry = ProjectSessionRegistry()
        let window = try await openWindow(url, in: registry)
        XCTAssertEqual(registry.openCount, 1)

        let source = ProjectStatisticsSource()
        let store = try await source.load(url, from: registry)

        XCTAssertEqual(registry.openCount, 1, "Statistics must open nothing new")
        XCTAssertTrue(store === window.session.projectStore,
                      "Statistics must borrow the window's session, not open its own stores")
        XCTAssertTrue(source.store === window.session.projectStore)
        XCTAssertNotNil(source.store?.documentStore,
                        "the store's DocumentStore must still be alive after load")
        XCTAssertNotNil(source.store?.documentStore?.presenter,
                        "and still open — it is the window's live store")

        // A re-run (a spurious re-appear) acquires nothing more.
        let again = try await source.load(url, from: registry)
        XCTAssertTrue(again === store)

        if let lease = source.relinquish() { await registry.release(lease) }
        XCTAssertEqual(registry.openCount, 1, "the window still holds the session")
        XCTAssertNotNil(window.session.documentStore.presenter,
                        "Statistics going must not close the window's stores")
        await registry.release(window)
        XCTAssertEqual(registry.openCount, 0)
    }

    /// (b) With nothing open, Statistics acquires the session, and giving its
    /// borrow back closes it.
    func test_withNoSession_statisticsAcquiresOneAndItsReleaseClosesIt() async throws {
        let url = try await makeProject()
        let registry = ProjectSessionRegistry()
        let source = ProjectStatisticsSource()

        let store = try await source.load(url, from: registry)
        XCTAssertEqual(registry.openCount, 1)
        let session = try XCTUnwrap(source.lease?.session)
        XCTAssertTrue(store === session.projectStore)
        XCTAssertNotNil(store?.documentStore)
        XCTAssertNil(session.attachment, "a reader attaches no window")
        XCTAssertNil(session.roster.compiler.configuredModel, "a reader configures no service")

        let lease = try XCTUnwrap(source.relinquish())
        XCTAssertNil(source.relinquish(), "the borrow is given back once")
        await registry.release(lease)
        XCTAssertEqual(registry.openCount, 0)
        XCTAssertNil(session.documentStore.presenter, "the last release closed the session")
    }

    /// A load whose keep-check fails (cancelled on a window already closed)
    /// hands its borrow straight back.
    func test_aBorrowStatisticsWillNotKeepGoesStraightBack() async throws {
        let url = try await makeProject()
        let registry = ProjectSessionRegistry()
        let source = ProjectStatisticsSource()

        let store = try await source.load(url, from: registry, keep: { false })
        XCTAssertNil(store)
        XCTAssertNil(source.lease)
        XCTAssertEqual(registry.openCount, 0, "a borrow nobody keeps must not hold the project open")
    }

    /// (c) Statistics borrows the window's session, then the window closes:
    /// every `claude` service is detached, yet Statistics' stores still work,
    /// a session-log reload included.
    func test_theWindowClosingDetachesTheServicesWhileStatisticsKeepsTheStores() async throws {
        let url = try await makeProject()
        let registry = ProjectSessionRegistry()
        let window = try await openWindow(url, in: registry)
        let session = window.session
        XCTAssertNotNil(session.roster.compiler.configuredModel, "premise: the window wired its services")

        let source = ProjectStatisticsSource()
        _ = try await source.load(url, from: registry)
        await registry.release(window)

        XCTAssertEqual(registry.openCount, 1, "Statistics still holds the session")
        XCTAssertNil(session.attachment, "the roster is detached from every window")
        let roster = session.roster
        XCTAssertNil(roster.compiler.configuredModel, "compiler")
        XCTAssertNil(roster.translator.configuredModel, "translator")
        XCTAssertNil(roster.designer.configuredModel, "designer")
        XCTAssertNil(roster.pipeline.configuredModel, "pipeline")
        let refused = await roster.coldCall.call(message: "x", preamble: nil, model: "m")
        XCTAssertEqual(refused, .failed(.sessionDied(detail: ColdCall.notWiredDetail)), "coldCall")

        // The stores still answer, and a reload reads the LIVE DocumentStore.
        let documentStore = try XCTUnwrap(source.store?.documentStore)
        XCTAssertNotNil(documentStore.presenter, "the stores are still open")
        XCTAssertFalse(try XCTUnwrap(source.store).manifest.title.isEmpty)
        let event = SessionEvent(id: UUID().uuidString, startedAt: Date(timeIntervalSince1970: 1_000),
                                 endedAt: Date(timeIntervalSince1970: 2_000), wordsNet: 42)
        try await documentStore.appendSessionEvent(event)
        let log = await source.loadSessionLog()
        XCTAssertEqual(log?.events.map(\.id), [event.id], "the reload must see the new session")

        if let lease = source.relinquish() { await registry.release(lease) }
        XCTAssertEqual(registry.openCount, 0)
    }

    // MARK: - The keep-check

    /// The keep rule itself: only a cancelled load on a window known gone
    /// hands its borrow back.
    func test_theKeepRuleReleasesOnlyACancelledLoadOnAWindowKnownGone() {
        let gone = NSWindow()   // never shown: not visible, not miniaturised
        XCTAssertFalse(MaughamEvent.isLive(gone), "premise: the handle is not live")
        XCTAssertFalse(ProjectStatisticsSource.keepsBorrow(cancelled: true, window: gone))
        XCTAssertTrue(ProjectStatisticsSource.keepsBorrow(cancelled: false, window: gone))
        XCTAssertTrue(ProjectStatisticsSource.keepsBorrow(cancelled: true, window: nil),
                      "a window not yet known keeps the borrow")
        XCTAssertTrue(ProjectStatisticsSource.keepsBorrow(cancelled: false, window: nil))
    }

    /// A REALLY cancelled load whose window handle is gone by the time the
    /// keep-check runs hands its borrow back — the handle arriving only after
    /// the load began, as `WindowAccessor`'s does.
    func test_aCancelledLoadOnAWindowGoneByTheKeepCheckHandsItsBorrowBack() async throws {
        let url = try await makeProject()
        let registry = ProjectSessionRegistry()
        let source = ProjectStatisticsSource()
        @MainActor final class Handle { var window: NSWindow? }
        let handle = Handle()   // nil when the load starts

        let loading = Task { @MainActor in
            try await source.load(url, from: registry, keep: {
                ProjectStatisticsSource.keepsBorrow(
                    cancelled: Task.isCancelled, window: handle.window)
            })
        }
        handle.window = NSWindow()   // filled after the task began, then closed
        loading.cancel()
        let store = try await loading.value

        XCTAssertNil(store)
        XCTAssertNil(source.lease)
        XCTAssertEqual(registry.openCount, 0,
                       "a borrow kept for a closed window would hold the project open for good")
    }

    /// The view's keep-check reads the LIVE window after the acquire, never a
    /// copy taken before it (a copy is routinely nil when `.task` starts).
    func test_theViewsKeepCheckReadsTheLiveWindow() throws {
        let source = try SourceTree.sourceOfType("ProjectStatisticsWindow", under: ["Maugham"])
        XCTAssertTrue(source.contains("cancelled: Task.isCancelled, window: self.window"),
                      "load()'s keep-check must read self.window inside the closure")
        XCTAssertFalse(source.contains("let window = self.window"),
                       "load() must not snapshot the window before the acquire")
    }
}
