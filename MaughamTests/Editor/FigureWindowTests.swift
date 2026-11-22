import XCTest
import AppKit
import SwiftUI
@testable import MaughamCore
@testable import Maugham

/// **The figure window's scene and session** (report plan 7d Task 8, R7d-5,
/// R7d-9): a figure window takes no borrow of its project's session, closes
/// when the project's last window detaches, closes at once with no project
/// window to belong to (a relaunch), never restores, and Format ▸ Table's
/// posts reach ITS grid while it is key. Against real projects, a real
/// registry and real sessions; the window is mounted through `TestWindow`.
/// Commands are posted, never clicked (tripwire 33).
@MainActor
final class FigureWindowTests: XCTestCase {

    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "FigureWindowTests-\(UUID().uuidString)"
    }

    override func tearDown() {
        UserDefaults().removePersistentDomain(forName: suiteName)
        suiteName = nil
        super.tearDown()
    }

    // MARK: - Helpers

    private func makeProject() async throws -> URL {
        try await ProjectFactory.createNovelProject(
            named: "FigureWindow-\(UUID().uuidString.prefix(6))", in: TestTemp.root)
    }

    /// A project window's borrow, attached as `ProjectWindow.load` attaches one.
    private func windowBorrow() throws -> ProjectSessionRegistry.Borrow {
        let preferences = UserPreferences(defaults: try XCTUnwrap(UserDefaults(suiteName: suiteName)))
        let canvas = CanvasModel()
        return .window(attach: { session in
            session.attachWindow(canvas: canvas, flash: { _ in }, preferences: preferences)
        }, isLive: { true })
    }

    private func openProjectWindow(_ url: URL, in registry: ProjectSessionRegistry) async throws
        -> ProjectSessionRegistry.Lease {
        try await registry.acquire(url, as: try windowBorrow()) { try await ProjectSession.open(url: url) }
    }

    private func mountFigureWindow<W: NSWindow>(
        _ key: FigureWindowKey, registry: ProjectSessionRegistry,
        grid: FigureWindowGrid? = nil, as type: W.Type = SilentTestWindow.self
    ) -> W {
        TestWindow.mount(FigureWindow(key: key, grid: grid).environment(registry),
                         size: CGSize(width: 480, height: 320), as: type)
    }

    // MARK: - Closing with the project

    /// The project's window closes: the figure window closes too, and the
    /// figure is no longer "in a window". It held no borrow — the registry's
    /// last release closed the session.
    func test_theFigureWindowClosesWithItsProjectWindow() async throws {
        let url = try await makeProject()
        let registry = ProjectSessionRegistry()
        let project = try await openProjectWindow(url, in: registry)
        let session = project.session
        let key = FigureWindowKey(projectURL: url, figureId: "fig-cash")

        let window = mountFigureWindow(key, registry: registry)
        let seated = await RunLoopPump.until(deadline: 2) { session.figureWindows.isOpen("fig-cash") }
        XCTAssertTrue(seated, "the figure window registers with its project's session")
        XCTAssertTrue(window.isVisible)
        XCTAssertEqual(registry.openCount, 1)

        await registry.release(project)
        XCTAssertFalse(window.isVisible, "the figure window closes with its project window")
        XCTAssertFalse(session.figureWindows.isOpen("fig-cash"))
        XCTAssertEqual(registry.openCount, 0, "the figure window held no borrow: the session closed")
    }

    /// A reader (Statistics) keeping the session open does not keep the
    /// figure window: it closes with the project's last WINDOW.
    func test_aReaderHoldingTheSessionDoesNotKeepTheFigureWindow() async throws {
        let url = try await makeProject()
        let registry = ProjectSessionRegistry()
        let project = try await openProjectWindow(url, in: registry)
        let reader = try await registry.acquire(url, as: .reader) { try await ProjectSession.open(url: url) }
        let session = project.session

        let window = mountFigureWindow(FigureWindowKey(projectURL: url, figureId: "fig-cash"), registry: registry)
        let seated = await RunLoopPump.until(deadline: 2) { session.figureWindows.isOpen("fig-cash") }
        XCTAssertTrue(seated)

        await registry.release(project)
        XCTAssertFalse(window.isVisible, "no project window is left")
        XCTAssertEqual(registry.openCount, 1, "the reader still holds the stores")
        await registry.release(reader)
    }

    /// With a second window on the project still open, closing one keeps the
    /// figure window: its project is still open.
    func test_anotherProjectWindowStillOpenKeepsTheFigureWindow() async throws {
        let url = try await makeProject()
        let registry = ProjectSessionRegistry()
        let first = try await openProjectWindow(url, in: registry)
        let second = try await openProjectWindow(url, in: registry)
        let session = first.session

        let window = mountFigureWindow(FigureWindowKey(projectURL: url, figureId: "fig-cash"), registry: registry)
        let seated = await RunLoopPump.until(deadline: 2) { session.figureWindows.isOpen("fig-cash") }
        XCTAssertTrue(seated)

        await registry.release(second)
        XCTAssertTrue(window.isVisible, "a window on the project is still open")
        XCTAssertTrue(session.figureWindows.isOpen("fig-cash"))

        await registry.release(first)
        XCTAssertFalse(window.isVisible)
    }

    /// The figure window itself closing takes it off the session's list.
    func test_closingTheFigureWindowForgetsIt() async throws {
        let url = try await makeProject()
        let registry = ProjectSessionRegistry()
        let project = try await openProjectWindow(url, in: registry)
        let session = project.session

        let window = mountFigureWindow(FigureWindowKey(projectURL: url, figureId: "fig-cash"), registry: registry)
        let seated = await RunLoopPump.until(deadline: 2) { session.figureWindows.isOpen("fig-cash") }
        XCTAssertTrue(seated)

        window.close()
        let forgotten = await RunLoopPump.until(deadline: 2) { !session.figureWindows.isOpen("fig-cash") }
        XCTAssertTrue(forgotten, "a closed figure window is no longer one the card names")
        await registry.release(project)
    }

    // MARK: - No restoration

    /// A figure window with no project window to belong to — what a relaunch
    /// would restore — closes at once and registers nowhere.
    func test_aFigureWindowWithNoProjectClosesAtOnce() async throws {
        let url = try await makeProject()
        let registry = ProjectSessionRegistry()
        let window = mountFigureWindow(FigureWindowKey(projectURL: url, figureId: "fig-cash"), registry: registry)
        let closed = await RunLoopPump.until(deadline: 2) { !window.isVisible }
        XCTAssertTrue(closed, "an orphaned figure window closes")
        XCTAssertEqual(registry.openCount, 0, "it opened no session")

        // A session a reader holds with no project window is no home either.
        let reader = try await registry.acquire(url, as: .reader) { try await ProjectSession.open(url: url) }
        let again = mountFigureWindow(FigureWindowKey(projectURL: url, figureId: "fig-cash"), registry: registry)
        let closedAgain = await RunLoopPump.until(deadline: 2) { !again.isVisible }
        XCTAssertTrue(closedAgain, "a reader's session has no project window")
        XCTAssertFalse(reader.session.figureWindows.isOpen("fig-cash"))
        await registry.release(reader)
    }

    /// The window is never restorable, and the scene says so: the `figure`
    /// `WindowGroup` disables restoration.
    func test_theFigureWindowNeverRestores() async throws {
        let url = try await makeProject()
        let registry = ProjectSessionRegistry()
        let project = try await openProjectWindow(url, in: registry)
        let window = mountFigureWindow(FigureWindowKey(projectURL: url, figureId: "fig-cash"), registry: registry)
        let seated = await RunLoopPump.until(deadline: 2) { project.session.figureWindows.isOpen("fig-cash") }
        XCTAssertTrue(seated)
        XCTAssertFalse(window.isRestorable)
        await registry.release(project)

        func squeezed(_ s: String) -> String { s.filter { !$0.isWhitespace } }
        let app = squeezed(try SourceTree.read("Maugham/MaughamApp.swift"))
        let scene = try XCTUnwrap(app.range(of: "WindowGroup(id:FigureWindowKey.sceneID,for:FigureWindowKey.self)"),
                                  "the figure scene is declared")
        let after = app[scene.upperBound...]
        let end = after.range(of: "WindowGroup(")?.lowerBound ?? after.endIndex
        XCTAssertTrue(after[..<end].contains(".restorationBehavior(.disabled)"),
                      "the figure scene is never restored")
    }

    // MARK: - The menus

    /// Format ▸ Table's post reaches the figure window's grid while that
    /// window is key, and not while another is.
    func test_formatTableReachesTheFigureWindowsGridWhileItIsKey() async throws {
        let url = try await makeProject()
        let registry = ProjectSessionRegistry()
        let project = try await openProjectWindow(url, in: registry)
        let grid = FigureWindowGrid()
        var received: [FigureTableCommand] = []
        grid.perform = { received.append($0) }

        let window: KeyTestWindow = mountFigureWindow(
            FigureWindowKey(projectURL: url, figureId: "fig-cash"), registry: registry, grid: grid,
            as: KeyTestWindow.self)
        let seated = await RunLoopPump.until(deadline: 2) { project.session.figureWindows.isOpen("fig-cash") }
        XCTAssertTrue(seated)

        MaughamEvent.postFigureTableCommand(.insertRowBelow)
        XCTAssertEqual(received, [.insertRowBelow], "the key figure window's grid takes the command")

        window.reportsKey = false
        MaughamEvent.postFigureTableCommand(.sortAscending)
        XCTAssertEqual(received, [.insertRowBelow], "a figure window that is not key takes nothing")
        await registry.release(project)
    }

    /// The menu reads the figure window's OWN presence (its focused value),
    /// and the project window answers the open post.
    func test_theWindowsPublishTheirPresenceAndTheProjectWindowOpens() throws {
        func squeezed(_ s: String) -> String { s.filter { !$0.isWhitespace } }
        let figure = squeezed(try SourceTree.read("Maugham/Editor/FigureWindow.swift"))
        XCTAssertTrue(figure.contains(squeezed(".modifier(FigureTableMenuModifier(presence: grid.presence))")))
        let window = squeezed(try SourceTree.read("Maugham/Views/ProjectWindow.swift"))
        XCTAssertTrue(window.contains(squeezed(".modifier(FigureWindowOpenModifier(projectURL: url, window: window))")))
    }

    // MARK: - Opening

    /// The open post names a figure; the project window opens it on its own
    /// project.
    func test_theOpenPostOpensTheFigureOnTheWindowsProject() throws {
        let url = TestTemp.root.appendingPathComponent("Book")
        let note = Notification(name: .maughamOpenFigureWindow, object: nil,
                                userInfo: [MaughamEvent.figureWindowFigureIdKey: "fig-cash"])
        XCTAssertEqual(FigureWindowOpenModifier.key(for: note, projectURL: url),
                       FigureWindowKey(projectURL: url, figureId: "fig-cash"))
        XCTAssertNil(FigureWindowOpenModifier.key(
            for: Notification(name: .maughamOpenFigureWindow), projectURL: url))

        let key = FigureWindowKey(projectURL: url, figureId: "fig-cash")
        let decoded = try JSONDecoder().decode(FigureWindowKey.self, from: JSONEncoder().encode(key))
        XCTAssertEqual(decoded, key, "the scene's value survives its encoding")
    }

    // MARK: - The registry

    /// Two windows on one figure are counted apart; `closeAll` closes each
    /// once and a late `closed` does nothing.
    func test_theRegistryClosesEachWindowOnce() {
        let windows = FigureWindows()
        var closes: [String] = []
        let a = windows.opened("fig-a") { closes.append("a") }
        _ = windows.opened("fig-a") { closes.append("a2") }
        _ = windows.opened("fig-b") { closes.append("b") }
        XCTAssertEqual(windows.openFigureIds, ["fig-a", "fig-b"])

        windows.closed(a)
        XCTAssertTrue(windows.isOpen("fig-a"), "the other window on fig-a is still open")

        windows.closeAll()
        XCTAssertEqual(closes.sorted(), ["a2", "b"])
        XCTAssertTrue(windows.openFigureIds.isEmpty)
        windows.closed(a)
        windows.closeAll()
        XCTAssertEqual(closes.count, 2, "nothing closes twice")
    }
}
