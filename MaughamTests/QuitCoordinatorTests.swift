import XCTest
import AppKit
@testable import MaughamCore
@testable import Maugham

/// **⌘Q waits for the stores to close** (hardening 11-11 plan 2 final
/// review, G1): `QuitCoordinator` answers `applicationShouldTerminate` —
/// now, when no project is open; later, replying once every open project's
/// close has finished, or at the bound, whichever is first. The clock is
/// injected: nothing here sleeps.
@MainActor
final class QuitCoordinatorTests: XCTestCase {

    /// A step a test holds open until it says so; asked before or after.
    @MainActor
    private final class Gate {
        private var opened = false
        private var waiting: [CheckedContinuation<Void, Never>] = []
        func wait() async {
            if opened { return }
            await withCheckedContinuation { waiting.append($0) }
        }
        func open() {
            opened = true
            let resumed = waiting
            waiting = []
            for continuation in resumed { continuation.resume() }
        }
    }

    /// What happened, in order.
    @MainActor
    private final class Log {
        var events: [String] = []
        var bounds: [Duration] = []
        let replied = Gate()
        func reply() {
            events.append("reply")
            replied.open()
        }
    }

    private var gates: [Gate] = []

    override func tearDown() async throws {
        // No step is left suspended for ever.
        for gate in gates { gate.open() }
        gates = []
    }

    private func gate() -> Gate {
        let gate = Gate()
        gates.append(gate)
        return gate
    }

    /// A coordinator over `closers` whose bound elapses when `bound` opens.
    private func coordinator(_ closers: [QuitCoordinator.Closer], bound: Gate, log: Log) -> QuitCoordinator {
        QuitCoordinator(closers: { closers }, wait: { duration in
            log.bounds.append(duration)
            await bound.wait()
        })
    }

    private func closer(_ name: String, holding gate: Gate, log: Log) -> QuitCoordinator.Closer {
        return {
            log.events.append("\(name) began")
            await gate.wait()
            log.events.append("\(name) ended")
        }
    }

    // MARK: - The decision

    /// **Every closer finished → the reply, after the last.**
    func test_theReplyComesAfterTheLastCloserHasFinished() async {
        let log = Log()
        let first = gate(), second = gate(), bound = gate()
        let quit = coordinator([closer("a", holding: first, log: log), closer("b", holding: second, log: log)],
                               bound: bound, log: log)

        XCTAssertEqual(quit.quitRequested(reply: log.reply), .later)
        first.open()
        // "a" has ended and "b" has not: no reply may have been made.
        await Task.yield()
        second.open()
        await log.replied.wait()

        XCTAssertEqual(log.events.filter { $0 == "reply" }.count, 1, "\(log.events)")
        XCTAssertEqual(log.events.last, "reply", "after the last closer: \(log.events)")
        XCTAssertEqual(Set(log.events.dropLast()), ["a began", "b began", "a ended", "b ended"], "\(log.events)")
        XCTAssertTrue(quit.hasBegun)
        // The bound passing afterwards replies no second time.
        bound.open()
        await Task.yield()
        await Task.yield()
        XCTAssertEqual(log.events.filter { $0 == "reply" }.count, 1, "\(log.events)")
    }

    /// **A closer that never finishes → the reply at the bound** (ten
    /// seconds): never a hung quit. The closer ending later replies no
    /// second time.
    func test_aCloserThatNeverFinishesIsLeftAtTheBound() async {
        let log = Log()
        let stuck = gate(), bound = gate(), began = gate(), ended = gate()
        let quit = coordinator([{
            log.events.append("stuck began")
            began.open()
            await stuck.wait()
            log.events.append("stuck ended")
            ended.open()
        }], bound: bound, log: log)

        XCTAssertEqual(quit.quitRequested(reply: log.reply), .later)
        await began.wait()
        bound.open()
        await log.replied.wait()

        XCTAssertEqual(log.events, ["stuck began", "reply"], "replied with the closer still running")
        XCTAssertEqual(log.bounds, [.seconds(10)], "the bound is ten seconds")
        XCTAssertEqual(QuitCoordinator.bound, .seconds(10))
        stuck.open()
        await ended.wait()
        await Task.yield()
        await Task.yield()
        XCTAssertEqual(log.events, ["stuck began", "reply", "stuck ended"], "one reply: \(log.events)")
    }

    /// **No open project → quit now**: nothing is waited for, no reply is owed.
    func test_withNoOpenProjectTheQuitIsImmediate() async {
        let log = Log()
        let quit = coordinator([], bound: gate(), log: log)

        XCTAssertEqual(quit.quitRequested(reply: log.reply), .now)
        await Task.yield()

        XCTAssertEqual(log.events, [], "no reply is made for an immediate quit")
        XCTAssertEqual(log.bounds, [], "and no clock is started")
        XCTAssertFalse(quit.hasBegun)
    }

    /// **A second quit request while one is pending starts no second
    /// round**: the closers run once, and one reply answers both.
    func test_aSecondRequestWhileOnePendsStartsNoSecondRound() async {
        let log = Log()
        let held = gate(), bound = gate()
        var asked = 0
        let quit = QuitCoordinator(closers: {
            asked += 1
            return [self.closer("a", holding: held, log: log)]
        }, wait: { _ in await bound.wait() })

        XCTAssertEqual(quit.quitRequested(reply: log.reply), .later)
        XCTAssertEqual(quit.quitRequested(reply: log.reply), .later, "still pending")
        held.open()
        await log.replied.wait()
        await Task.yield()
        await Task.yield()

        XCTAssertEqual(asked, 1, "the closers were asked for once")
        XCTAssertEqual(log.events, ["a began", "a ended", "reply"], "one round, one reply")
    }

    /// **The closers finishing and the bound passing together make one
    /// reply**: both are ready before either task has run, and the reply
    /// closure is still called exactly once.
    func test_theClosersFinishingAndTheBoundPassingTogetherReplyOnce() async {
        let log = Log()
        let held = gate(), bound = gate(), ended = gate()
        let quit = coordinator([{
            await held.wait()
            ended.open()
        }], bound: bound, log: log)

        held.open()
        bound.open()
        XCTAssertEqual(quit.quitRequested(reply: log.reply), .later)
        await log.replied.wait()
        await ended.wait()
        await Task.yield()
        await Task.yield()

        XCTAssertEqual(log.events, ["reply"], "exactly one reply: \(log.events)")
    }

    /// **The quit coordinator only delays the quit** (the updater's
    /// constraints): its file never names the update install — the swap
    /// helper is launched where it always was, in `willTerminate`, after the
    /// reply — and the delegate's one reply is `true`, so a deferred quit is
    /// never cancelled. The app's `willTerminate` observer still holds the
    /// one install-on-quit hand-off.
    func test_theQuitCoordinatorNeverTouchesTheInstallAndNeverCancelsTheQuit() throws {
        let file = try SourceTree.sourceOfType("QuitCoordinator", under: ["Maugham"])
        let code = String(decoding: SourceTree.mask(file), as: UTF8.self)
        for name in ["launchSwapHelper", "pendingQuitInstall", "UpdateInstaller", "UpdateChecker", "performInstall"] {
            XCTAssertFalse(code.contains(name), "QuitCoordinator.swift must not name \(name): the install stays in willTerminate")
        }
        XCTAssertFalse(code.contains("reply(toApplicationShouldTerminate: false)"), "a deferred quit is never cancelled")
        XCTAssertFalse(code.contains(".terminateCancel"), "a deferred quit is never cancelled")
        XCTAssertEqual(code.components(separatedBy: "reply(toApplicationShouldTerminate:").count - 1, 1,
                       "one reply site, and it says true")
        XCTAssertTrue(code.contains("reply(toApplicationShouldTerminate: true)"))

        let app = try SourceTree.sourceOfType("MaughamApp", under: ["Maugham"])
        let appCode = String(decoding: SourceTree.mask(app), as: UTF8.self)
        XCTAssertEqual(appCode.components(separatedBy: "UpdateChecker.shared.pendingQuitInstall").count - 1, 1,
                       "the dismissed update is handed to the helper in one place")
        let quitSetUp = try XCTUnwrap(appCode.range(of: "MaughamAppDelegate.quit ="))
        let observer = try XCTUnwrap(appCode.range(of: "NSApplication.willTerminateNotification"))
        let handOff = try XCTUnwrap(appCode.range(of: "UpdateChecker.shared.pendingQuitInstall"))
        XCTAssertTrue(quitSetUp.lowerBound < observer.lowerBound && observer.lowerBound < handOff.lowerBound,
                      "and that place is the willTerminate observer, which runs after the reply")
    }

    // MARK: - The stores

    /// **A Research table's pending edit is on disk before the reply**: the
    /// closers are the session registry's own (`quitClosers`), over a real
    /// project with a grid's table open and an edit its debounce has not
    /// written.
    func test_aTablesPendingEditIsOnDiskBeforeTheReply() async throws {
        let url = try await ProjectFactory.createNovelProject(
            named: "Quit-\(UUID().uuidString.prefix(6))", in: TestTemp.root)
        let registry = ProjectSessionRegistry()
        let lease = try await registry.acquire(url, as: .reader) { try await ProjectSession.open(url: url) }
        let session = lease.session
        let source = TestTemp.root.appendingPathComponent("quit-src-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("Year,Revenue\n2025,10\n".utf8).write(to: source.appendingPathComponent("model.csv"))
        let item = try await session.projectStore.addResearchAsset(
            parentId: nil, fromURL: source.appendingPathComponent("model.csv"))
        let file = url.appendingPathComponent(try XCTUnwrap(item.path))
        let host = try await session.documentStore.openResearchTable(itemId: item.id)
        host.saveDelay = .seconds(3600)   // the debounce never fires here
        let table = host.state.table
        try await host.setCell(Cell(content: .value(.number(11))),
                               at: CellKey(row: table.rows[1], column: table.columns[1]), undoManager: nil)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "Year,Revenue\n2025,10\n",
                       "precondition: the edit is pending, not written")

        let bound = gate()
        let quit = QuitCoordinator(closers: { registry.quitClosers() }, wait: { _ in await bound.wait() })
        var onDiskAtTheReply: String?
        let replied = gate()
        let answer = quit.quitRequested(reply: {
            onDiskAtTheReply = try? String(contentsOf: file, encoding: .utf8)
            replied.open()
        })
        XCTAssertEqual(answer, .later, "an open project is waited for")
        await replied.wait()

        XCTAssertEqual(onDiskAtTheReply, "Year,Revenue\n2025,11\n", "the edit was on disk when the quit was let go")
        XCTAssertFalse(host.isDirty)
        await registry.release(lease)
    }

    /// **With no project open the registry offers no closer**, so the quit
    /// is immediate.
    func test_theRegistryOffersNoCloserWithNoProjectOpen() {
        XCTAssertTrue(ProjectSessionRegistry().quitClosers().isEmpty)
    }

    // MARK: - The delegate

    /// **The app delegate's answer**: with no coordinator, or in a test
    /// host, quit now (a gate's worker is never held); otherwise what the
    /// coordinator says.
    func test_theDelegateAnswersFromTheCoordinator() async {
        let log = Log()
        let held = gate()
        let quit = coordinator([closer("a", holding: held, log: log)], bound: gate(), log: log)

        XCTAssertEqual(MaughamAppDelegate.answer(nil, isTestHost: false, reply: log.reply), .terminateNow)
        XCTAssertEqual(MaughamAppDelegate.answer(quit, isTestHost: true, reply: log.reply), .terminateNow)
        XCTAssertFalse(quit.hasBegun, "a test host starts no round")
        XCTAssertEqual(MaughamAppDelegate.answer(quit, isTestHost: false, reply: log.reply), .terminateLater)
        held.open()
        await log.replied.wait()
        XCTAssertEqual(log.events, ["a began", "a ended", "reply"])

        let idle = coordinator([], bound: gate(), log: log)
        XCTAssertEqual(MaughamAppDelegate.answer(idle, isTestHost: false, reply: log.reply), .terminateNow)
    }

    /// **A quit the app asks for itself still hears its reply** (0.46.0's
    /// *Restart & Update* hang): asked from a main-actor task, as the update
    /// install asks, the quit is deferred and AppKit spins a run loop inside
    /// `terminate` until the reply. `terminate` here is AppKit's part: defer,
    /// then spin until replied. Called straight from the task, the closers
    /// never run and the spin ends unanswered.
    func test_aQuitTheAppAsksForFromATaskStillHearsItsReply() async {
        let quit = QuitCoordinator(
            closers: { [{ await Task.yield() }] },
            wait: { _ in try? await Task.sleep(for: .seconds(60)) })
        let spun = expectation(description: "AppKit's nested loop ended")
        var replied = false
        MaughamAppDelegate.requestQuit {
            XCTAssertEqual(quit.quitRequested { replied = true }, .later)
            let giveUp = Date().addingTimeInterval(3)
            while !replied && Date() < giveUp {
                RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02))
            }
            spun.fulfill()
        }
        await fulfillment(of: [spun], timeout: 10)
        XCTAssertTrue(replied, "the closers must run, and reply, while terminate's own run loop spins")
    }

    /// **`terminate` is called in one place**: `requestQuit`. A second call
    /// site inside a task or a `DispatchQueue.main` block is the hang again.
    func test_terminateIsCalledOnlyThroughRequestQuit() throws {
        var sites: [String] = []
        for path in try SourceTree.swiftFiles(under: "Maugham") {
            let code = String(decoding: SourceTree.mask(try SourceTree.read(path)), as: UTF8.self)
            let count = code.components(separatedBy: "NSApp.terminate(").count - 1
                + code.components(separatedBy: "NSApplication.shared.terminate(").count - 1
            if count > 0 { sites.append("\((path as NSString).lastPathComponent)×\(count)") }
        }
        XCTAssertEqual(sites, ["QuitCoordinator.swift×1"],
                       "ask MaughamAppDelegate.requestQuit(): a terminate called from a task deadlocks a deferred quit")
    }

    /// **One place closes the stores at quit**: the app installs the
    /// delegate and hands it the registry's closers, the delegate replies to
    /// AppKit, and the project window's own quit arm — which started a close
    /// nothing waited for — is gone, so no store is closed twice.
    func test_theAppWiresTheDelegateAndTheWindowNoLongerClosesTheStoresAtQuit() throws {
        let app = try SourceTree.sourceOfType("MaughamApp", under: ["Maugham"])
        XCTAssertTrue(app.contains("@NSApplicationDelegateAdaptor(MaughamAppDelegate.self)"),
                      "the app must install the delegate that defers the quit")
        XCTAssertTrue(app.contains("sessions.quitClosers()"),
                      "the coordinator's closers are the session registry's")
        let delegate = try SourceTree.sourceOfType("MaughamAppDelegate", under: ["Maugham"])
        XCTAssertTrue(delegate.contains("reply(toApplicationShouldTerminate: true)"),
                      "the deferred quit is let go through AppKit's reply")
        let window = try SourceTree.sourceOfType("ProjectWindow", under: ["Maugham"])
        XCTAssertFalse(window.contains(".maughamAppWillTerminate"),
                       "ProjectWindow must not close its stores at willTerminate: the quit coordinator "
                       + "has closed them, and a second close would race the first")
    }
}
