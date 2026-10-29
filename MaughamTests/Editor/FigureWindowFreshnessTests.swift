import XCTest
import AppKit
import SwiftUI
@testable import MaughamCore
@testable import Maugham

/// **A figure window's grid never goes stale** (concern 2 and the gate):
/// its values reseed when another figure it reads changes, a park elsewhere
/// turns it read-only through the same card edge, and a trust change re-asks
/// through the door — the window's `FigureWindowGrid` opened over a
/// signed book's stores (no window needed: the grid is the frame's).
@MainActor
final class FigureWindowFreshnessTests: FigureGridMountedTestCase {

    override func setUp() async throws {
        try await super.setUp()
        let identities = LocalIdentities.softwareForTesting()
        Document.localIdentitiesForTesting = identities
        Document.deviceStateForTesting = OpLogDeviceState(
            fileURL: temp.url.appendingPathComponent("op-log-state.json"))
        Document.registryCacheForTesting = RegistryCache(
            fileURL: temp.url.appendingPathComponent("registry-cache.json"),
            identity: identities.author.fingerprint)
        Document.admissionMemoryForTesting = AdmissionMemory(
            fileURL: temp.url.appendingPathComponent("admission-memory.json"),
            identity: identities.author.fingerprint)
    }

    override func tearDown() async throws {
        for grid in grids {
            grid.finish()
            await grid.finishing?.value
        }
        grids = []
        try await super.tearDown()
        Document.localIdentitiesForTesting = nil
        Document.deviceStateForTesting = nil
        Document.registryCacheForTesting = nil
        Document.admissionMemoryForTesting = nil
    }

    private var grids: [FigureWindowGrid] = []

    private func openGrid(_ m: Mounted, _ figureId: String) async throws -> FigureGridController {
        let ds = try XCTUnwrap(m.store.documentStore)
        let grid = FigureWindowGrid()
        grids.append(grid)
        grid.open(figureId: figureId, store: ds, projectStore: m.store, windows: FigureWindows(), close: {})
        await grid.opening?.value
        return try XCTUnwrap(grid.controller, grid.container.message)
    }

    private func key(_ table: FigureTable, _ column: Int, _ row: Int) -> CellKey {
        CellKey(row: table.rows[row - 1], column: table.columns[column - 1])
    }

    /// Another figure this one reads changes: the window's values reseed.
    func test_anotherFigureChangingReseedsTheWindowsValues() async throws {
        let m = try await mount()
        let ds = try XCTUnwrap(m.store.documentStore)
        let t = try XCTUnwrap(m.figure)
        let u = try await m.store.createFigure(kind: .table, name: "u", piece: nil)
        let uDoc = try await ds.openFigure(figureId: u.id)
        let u1 = key(uDoc.state.table, 1, 1)
        try await uDoc.setCell(Cell(content: .value(.number(5))), at: u1)
        let tDoc = try await ds.openFigure(figureId: t.id)
        let t1 = key(tDoc.state.table, 1, 1)
        let names = FormulaNames(figures: [.init(id: u.id, name: "u", table: uDoc.state.table)])
        guard case .success(let f) = FormulaParser.parse("u!A1*2", in: tDoc.state.table, names: names)
        else { return XCTFail("the formula did not parse") }
        try await tDoc.setCell(Cell(content: .formula(f)), at: t1)

        let c = try await openGrid(m, t.id)
        XCTAssertEqual(c.figureGridDisplay(at: t1), "10", "premise")

        try await uDoc.setCell(Cell(content: .value(.number(7))), at: u1)
        let reseeded = await RunLoopPump.until(deadline: 5) { c.figureGridDisplay(at: t1) == "14" }
        XCTAssertTrue(reseeded, "the window reads u again: \(c.figureGridDisplay(at: t1))")
    }

    /// A park elsewhere reaches the window as a card edge: read-only, parked.
    func test_aParkElsewhereTurnsTheWindowReadOnly() async throws {
        let m = try await mount()
        let t = try XCTUnwrap(m.figure)
        let c = try await openGrid(m, t.id)
        XCTAssertEqual(c.mode, .editable)
        _ = try await m.store.sendToResearch(figureId: t.id, scope: .shared)
        let parked = await RunLoopPump.until(deadline: 5) { c.mode == .readOnly(.parked) }
        XCTAssertTrue(parked, "the window's gate was asked again: \(c.mode)")
    }

    /// A trust change (another author admitted to the chapter, so this Mac
    /// yields on its figure) re-asks the window's gate through the door.
    func test_aTrustChangeReasksTheWindowsGate() async throws {
        let m = try await mount()
        let ds = try XCTUnwrap(m.store.documentStore)
        let c = try await openGrid(m, try XCTUnwrap(m.figure?.id))
        XCTAssertEqual(c.mode, .editable)
        let sam = LocalIdentities.softwareForTesting()
        _ = try await ds.admit(device: sam.author.fingerprint, label: "Sam", ownName: "Sam’s Mac",
                               permit: .author(.pieces([try XCTUnwrap(m.store.manifest.structure.first?.id)])))
        await ds.postureSettled()
        await c.postureChange?.value
        XCTAssertEqual(c.mode, .readOnly(.notYours))
    }

    /// **I1: Research changing refills the window's cards** — the grid's own
    /// manifest edge (`watchTheManifest`), the centre's grid's too: a pin's
    /// source and a `research:` formula's value move with Research, which no
    /// figure op announces. Counted as fills of the grid's own cache, cut off
    /// from the store's triggers; Research moves in memory only.
    func test_researchChangingRefillsTheWindowsCards() async throws {
        let m = try await mount()
        let folder = temp.url.appendingPathComponent("outside-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let csv = folder.appendingPathComponent("budget.csv")
        try Data("A,B\n1,2\n".utf8).write(to: csv)
        _ = try await m.store.addResearchAsset(parentId: nil, fromURL: csv)
        let c = try await openGrid(m, try XCTUnwrap(m.figure?.id))
        _ = c
        let grid = try XCTUnwrap(grids.last)
        let cards = try XCTUnwrap(grid.cards)
        let filled = await RunLoopPump.until(deadline: 5) { cards.fills > 0 }
        XCTAssertTrue(filled, "premise: the window's cards filled")
        let before = await FigureInspectorTests.fillsHearingOnlyTheOwner(cards, store: try XCTUnwrap(m.store.documentStore))
        // In memory only, as an adopted manifest moves it: no op, no file event.
        m.store.manifest.research[0].title = "budget 2"
        let refilled = await RunLoopPump.until(deadline: 5) { cards.fills > before }
        XCTAssertTrue(refilled, "a Research change refills the window's cards")
    }
}
