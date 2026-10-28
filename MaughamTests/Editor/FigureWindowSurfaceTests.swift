import XCTest
import AppKit
import SwiftUI
@testable import MaughamCore
@testable import Maugham

/// **The figure window's surface** (report plan 7d Task 9, R7d-5, R7d-6,
/// R7d-7): the same grid in a window, against the project window's
/// `DocumentStore` — the caption read-only, the name editable, its own
/// undo stack for its life and no step anywhere at its close, the visit
/// finished when the window closes (with its project too — Review Focus 3),
/// and Send to Research closing it first. Real projects, a real registry and
/// real sessions; windows through `TestWindow`; acts asked of the controller
/// (a bar's or a menu's verb), never clicked (tripwire 33).
@MainActor
final class FigureWindowSurfaceTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        FontWarmup.ensure()
    }

    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "FigureWindowSurfaceTests-\(UUID().uuidString)"
    }

    override func tearDown() {
        UserDefaults().removePersistentDomain(forName: suiteName)
        suiteName = nil
        super.tearDown()
    }

    // MARK: - Helpers

    private struct Project {
        let registry: ProjectSessionRegistry
        let lease: ProjectSessionRegistry.Lease
        let figure: FigureRecord
        let chapter: StructureItem
        var session: ProjectSession { lease.session }
    }

    /// A novel open in a project window, holding a 3×3 table `t` in its first chapter.
    private func openProject() async throws -> Project {
        let url = try await ProjectFactory.createNovelProject(
            named: "FigureSurface-\(UUID().uuidString.prefix(6))", in: TestTemp.root)
        let registry = ProjectSessionRegistry()
        let preferences = UserPreferences(defaults: try XCTUnwrap(UserDefaults(suiteName: suiteName)))
        let canvas = CanvasModel()
        let lease = try await registry.acquire(url, as: .window(attach: { session in
            session.attachWindow(canvas: canvas, flash: { _ in }, preferences: preferences)
        }, isLive: { true })) { try await ProjectSession.open(url: url) }
        let store = lease.session.projectStore
        let chapter = try XCTUnwrap(store.manifest.structure.first)
        let figure = try await store.createFigure(kind: .table, name: "t", piece: chapter.id, rows: 3, columns: 3)
        return Project(registry: registry, lease: lease, figure: figure, chapter: chapter)
    }

    /// The figure window mounted on `project`'s table, its visit opened.
    private func openWindow(
        _ project: Project, handoff: FigureWindows.Handoff? = nil
    ) async throws -> (KeyTestWindow, FigureWindowGrid, FigureGridController) {
        if let handoff { project.session.figureWindows.handOff(project.figure.id, handoff) }
        let grid = FigureWindowGrid()
        let key = FigureWindowKey(projectURL: project.session.url, figureId: project.figure.id)
        let window = TestWindow.mount(FigureWindow(key: key, grid: grid).environment(project.registry),
                                      size: CGSize(width: 640, height: 400), as: KeyTestWindow.self)
        addTeardownBlock { @MainActor in
            window.reportsKey = false
            window.close()
        }
        let opened = await RunLoopPump.until(deadline: 5) { grid.controller != nil }
        XCTAssertTrue(opened, "the window's visit opened: \(grid.container.message)")
        return (window, grid, try XCTUnwrap(grid.controller))
    }

    private func handoff(_ project: Project) -> FigureWindows.Handoff {
        FigureWindows.Handoff(number: "Table 2", caption: "Cash flow", piece: project.chapter.id,
                              typography: .defaults)
    }

    private func cell(_ c: FigureGridController, _ column: Int, _ row: Int) -> CellKey {
        let table = c.host.state.table
        return CellKey(row: table.rows[row - 1], column: table.columns[column - 1])
    }

    /// `text` typed into `key` and left open (no Return).
    private func typeOpen(_ c: FigureGridController, _ key: CellKey, _ text: String) {
        c.handle(.click(key, extend: false))
        c.handle(.type(text))
        c.handle(.editTextChanged(text))
    }

    // MARK: - The surface (R7d-6)

    /// The window shows the same grid in its panel with the keys; the bottom
    /// bar shows "Table N · caption" as the opening grid handed them over,
    /// the caption locked (it is the text's) and the name open; ⤢ is not
    /// offered in the window itself; Format ▸ Table reads its presence.
    func test_theWindowMountsTheGrid_theCaptionReadOnly_theNameEditable() async throws {
        let project = try await openProject()
        let (window, grid, c) = try await openWindow(project, handoff: handoff(project))

        XCTAssertTrue(grid.panel?.superview === grid.container, "the panel is the window's content")
        XCTAssertTrue(grid.panel?.gridView === c.gridView)
        XCTAssertTrue(window.firstResponder === c.gridView, "the grid has the keys")
        XCTAssertEqual(c.bars.numberLabel.stringValue, "Table 2")
        XCTAssertEqual(c.bars.captionField.stringValue, "Cash flow")
        XCTAssertFalse(c.bars.captionField.isEditable, "the caption is the text's (R7d-6)")
        XCTAssertTrue(c.bars.nameField.isEditable, "the name may be changed")
        XCTAssertTrue(c.bars.openInWindow.isHidden, "no ⤢ in the window")
        XCTAssertEqual(c.mode, .editable)
        XCTAssertEqual(grid.presence.menu, c.menuState, "Format ▸ Table reads the window's grid")
        XCTAssertTrue(c.menuState.isEnabled(.sendTo(.piece)), "the handed-over piece")

        c.perform(.caption("Something else"))
        XCTAssertEqual(c.bars.captionField.stringValue, "Cash flow", "a caption commit is refused")

        c.perform(.name("ledger"))
        await c.settleWrites()
        XCTAssertEqual(project.session.projectStore.manifest.figures?.first { $0.id == project.figure.id }?.name,
                       "ledger", "the name is renamed through the store")
        await project.registry.release(project.lease)
    }

    /// A view-only share makes the window's grid read-only, its name locked
    /// with the caption — read live, not a snapshot: the share flipping
    /// while the window is open turns it read-only and back.
    func test_aViewOnlyShareIsReadOnly_andAFlipWhileOpenReasks() async throws {
        let project = try await openProject()
        let windows = project.session.figureWindows
        windows.setShareIsReadOnly(true)
        let (_, _, c) = try await openWindow(project, handoff: handoff(project))
        XCTAssertEqual(c.mode, .readOnly(.viewOnlyShare))
        XCTAssertFalse(c.bars.nameField.isEditable)
        XCTAssertFalse(c.bars.captionField.isEditable)

        windows.setShareIsReadOnly(false)
        XCTAssertEqual(c.mode, .editable, "the share came back writable")
        XCTAssertTrue(c.bars.nameField.isEditable)
        windows.setShareIsReadOnly(true)
        XCTAssertEqual(c.mode, .readOnly(.viewOnlyShare), "and view-only again, mid-visit")
        await project.registry.release(project.lease)
    }

    /// **The line follows the book**: the index's "Table N" and caption,
    /// told while the window is open, reach its bottom bar (still locked).
    func test_theBottomBarFollowsTheLineAsTheBookChanges() async throws {
        let project = try await openProject()
        let (_, _, c) = try await openWindow(project, handoff: handoff(project))
        project.session.figureWindows.lineChanged(project.figure.id, number: "Table 3", caption: "Cash, revised")
        XCTAssertEqual(c.bars.numberLabel.stringValue, "Table 3")
        XCTAssertEqual(c.bars.captionField.stringValue, "Cash, revised")
        XCTAssertFalse(c.bars.captionField.isEditable)
        XCTAssertEqual(project.session.figureWindows.handoff(for: project.figure.id)?.caption, "Cash, revised")
        await project.registry.release(project.lease)
    }

    /// **Esc in a window closes nothing** (ruling 3): with nothing to cancel
    /// it does nothing; an open edit is still cancelled. Done closes the
    /// window, and the grid leaves ⌘W to the window.
    func test_escClosesNoWindow_doneDoes_andTheGridLeavesCommandW() async throws {
        let project = try await openProject()
        let (window, grid, c) = try await openWindow(project, handoff: handoff(project))
        let b2 = cell(c, 2, 2)
        typeOpen(c, b2, "4")
        c.handle(.escape)
        XCTAssertNil(c.host.state.table[b2], "Esc cancelled the open edit")
        c.handle(.escape)
        c.handle(.escape)
        XCTAssertTrue(window.isVisible, "Esc with nothing to cancel does nothing")
        XCTAssertFalse(grid.isFinished)
        let commandW = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: "w",
            charactersIgnoringModifiers: "w", isARepeat: false, keyCode: 13))
        XCTAssertFalse(c.gridView.performKeyEquivalent(with: commandW), "⌘W is the window's")

        c.perform(.done)
        XCTAssertFalse(window.isVisible, "Done closes the window")
        XCTAssertTrue(grid.isFinished)
        await project.registry.release(project.lease)
    }

    // MARK: - Its own undo, and the close (R7d-5)

    /// A write in the window lands on the window's own stack and records no
    /// visit; closing the window commits an open edit, lands every write,
    /// ends the visit and registers no step anywhere.
    func test_theWindowKeepsItsOwnStack_andClosingCommitsAndAddsNoStep() async throws {
        let project = try await openProject()
        let (window, grid, c) = try await openWindow(project, handoff: handoff(project))
        let b2 = cell(c, 2, 2), b3 = cell(c, 2, 3)
        typeOpen(c, b2, "4")
        c.handle(.returnKey(backward: false))
        await c.settleWrites()
        XCTAssertEqual(c.host.state.table[b2]?.content, .value(.number(4)))
        XCTAssertTrue(c.gridUndo.canUndo, "on the window's own stack")
        XCTAssertFalse(c.host.visitHasRecorded, "a window records no visit: nothing collapses at its close")
        let windowUndo = window.undoManager
        XCTAssertFalse(windowUndo?.canUndo ?? false, "nothing on the window's stack")

        typeOpen(c, b3, "5")
        window.close()
        XCTAssertTrue(grid.isFinished, "the visit ends with the window")
        XCTAssertNil(grid.presence.menu, "Format ▸ Table stands down")
        await grid.finishing?.value
        XCTAssertEqual(c.host.state.table[b3]?.content, .value(.number(5)), "the open edit was committed")
        XCTAssertFalse(windowUndo?.canUndo ?? false, "closing added no step")
        XCTAssertFalse(project.session.figureWindows.isOpen(project.figure.id))
        await project.registry.release(project.lease)
    }

    /// **Review Focus 3** (final review I3): the project's window closes —
    /// the figure window closes too, its open edit is committed, and the
    /// project's close awaits that write before its store closes: the cell
    /// is in the figure's history when the project is opened again. Nothing
    /// awaited here but the release itself.
    func test_reviewFocus3_closingTheProjectClosesTheWindowAndItsEditReachesTheBook() async throws {
        let project = try await openProject()
        let (window, grid, c) = try await openWindow(project, handoff: handoff(project))
        let a1 = cell(c, 1, 1)
        typeOpen(c, a1, "9")
        // The fold's commit waits at its turn, so a close that did not await
        // it would close the store first.
        FigureGridController.writeTurnForTesting = { try? await Task.sleep(for: .milliseconds(300)) }
        defer { FigureGridController.writeTurnForTesting = nil }

        await project.registry.release(project.lease)

        XCTAssertFalse(window.isVisible, "the figure window closed with its project")
        XCTAssertTrue(grid.isFinished)
        XCTAssertTrue(c.host.isClosed, "premise: the store closed under the host")
        let reopened = try await DocumentStore.open(url: project.session.url)
        let host = try await reopened.openFigure(figureId: project.figure.id)
        let kept = host.state.table[a1]?.content
        await reopened.close()
        XCTAssertEqual(kept, .value(.number(9)), "the open edit was written before the store closed")
        XCTAssertNil(grid.controller, "the closed window holds no grid (M11)")
    }

    /// **A close never hangs on a window's writes** (final review I3): past
    /// its bound, `settle` answers false and the session logs it (no surface
    /// outlives the project window, ruling N1); writes that land settle.
    func test_aCloseWaitsBoundedForTheWindowsWrites() async throws {
        let project = try await openProject()
        let windows = project.session.figureWindows
        let stuck = Task { @MainActor in _ = try? await Task.sleep(for: .seconds(30)) }
        defer { stuck.cancel() }
        windows.track(stuck)
        let started = ContinuousClock.now
        let landedInTime = await project.session.settleFigureWindows(within: .milliseconds(200))
        XCTAssertFalse(landedInTime)
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(5), "bounded")

        let landed = Task { @MainActor in }
        windows.track(landed)
        stuck.cancel()
        let settled = await windows.settle(within: .seconds(5))
        XCTAssertTrue(settled, "writes that land settle")
        await project.registry.release(project.lease)
    }

    // MARK: - Send to Research (R7d-7)

    /// From the window's grid: the window closes first, then the figure is
    /// parked in the piece's Research (a novel's chapter: shared, linked).
    func test_sendToResearchFromTheWindowClosesItAndParksTheFigure() async throws {
        let project = try await openProject()
        let (window, grid, c) = try await openWindow(project, handoff: handoff(project))

        c.performTableCommand(.sendTo(.piece))

        XCTAssertFalse(window.isVisible, "the window goes first")
        XCTAssertTrue(grid.isFinished)
        await grid.finishing?.value
        let parked = try await project.session.documentStore.figureIsParked(project.figure.id)
        XCTAssertTrue(parked, "the figure is in Research")
        let store = project.session.projectStore
        let item = try XCTUnwrap(store.manifest.research.first { $0.kind == .table })
        let chapter = try XCTUnwrap(store.manifest.structure.first { $0.id == project.chapter.id })
        XCTAssertEqual(chapter.linkedResearchIds ?? [], [item.id], "in the chapter's Research")
        await project.registry.release(project.lease)
    }
}
