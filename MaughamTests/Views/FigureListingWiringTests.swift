import XCTest
import SwiftUI
import MaughamCore
@testable import Maugham

/// **The window's figure listing with no editor mounted** (report plan 8a
/// Task 2): `ReferenceIndexWiring` — the window's own modifier, as
/// `ProjectWindow` mounts it — attaches the window's `ReferenceIndexHost` and
/// carries the binder's edge, so moving a chapter re-numbers the Figures
/// listing in Plan persona, whose centre is the canvas and mounts no
/// `EditorHost`. The pieces are closed: their text is their op log's.
@MainActor
final class FigureListingWiringTests: XCTestCase {

    private var temp: TempDirectory!
    private var windows: [NSWindow] = []
    private var documentStores: [DocumentStore] = []

    override func setUp() async throws { temp = TempDirectory() }

    override func tearDown() async throws {
        for window in windows { window.close() }
        windows.removeAll()
        for ds in documentStores { await ds.close() }
        documentStores.removeAll()
        temp.cleanup()
        temp = nil
    }

    private static let cash = FigureRecord(id: "fig-0a0a0a0a", name: "cash", kind: .table, piece: nil,
                                           path: "figures/cash.csv")
    private static let debt = FigureRecord(id: "fig-1b1b1b1b", name: "debt", kind: .table, piece: nil,
                                           path: "figures/debt.csv")

    func test_withNoEditorMounted_aStructureChangeReNumbersTheListing() async throws {
        let url = try await ProjectFactory.createNovelProject(
            named: "Figures-\(UUID().uuidString.prefix(6))", in: temp.url)
        let store = try await ProjectStore.load(from: url)
        _ = try await store.addStructureItem(parentId: nil, title: "Chapter Two", kind: .document(.markdown))
        let chapters = ProjectStore.collectDocuments(in: store.manifest.structure)
        XCTAssertEqual(chapters.count, 2, "fixture precondition: two chapters")
        let one = chapters[0], two = chapters[1]

        // Each chapter's figure line, written before anything opens it, then
        // bootstrapped into its op log and closed (ADR 0018's derived direction).
        for (chapter, record) in [(one, Self.cash), (two, Self.debt)] {
            let path = try XCTUnwrap(chapter.path)
            let climb = String(repeating: "../", count: path.split(separator: "/").count - 1)
            try "Prose.\n\n![\(record.name)](\(climb)\(record.path))\n".write(
                to: url.appendingPathComponent(path), atomically: true, encoding: .utf8)
            let doc = try await Document.load(url: url.appendingPathComponent(path), actor: .author,
                                              session: "s", presenter: nil)
            await doc.close()
        }
        store.manifest.figures = [Self.debt, Self.cash]
        await store.wordCountPopulationTask?.value
        let ds = try await DocumentStore.open(url: url)
        store.documentStore = ds
        ds.projectStore = store
        documentStores.append(ds)

        let host = ReferenceIndexHost()
        let listing = FigureListingModel()
        let control = EditorControl()
        let root = Color.clear.modifier(ReferenceIndexWiring(
            url: url, store: store, documentStore: ds, referenceIndex: host,
            figureListing: listing, control: control, window: nil))
        windows.append(TestWindow.mount(AnyView(root), size: CGSize(width: 200, height: 200)))

        // Waits on the numbers, not the order: before any build both are
        // unused, and "cash" sorts before "debt" by name anyway.
        let numbered = await pumpUntil(deadline: 10) {
            listing.rows.map(\.number) == ["Table 1", "Table 2"]
        }
        XCTAssertTrue(numbered, "the first build numbers both: \(listing.rows)")
        XCTAssertEqual(listing.rows.map(\.figureId), [Self.cash.id, Self.debt.id], "in chapter order")
        XCTAssertEqual(listing.rows.map(\.pieceOfLine), [one.id, two.id])
        XCTAssertGreaterThan(control.referenceIndexVersion, 0,
                             "the version reaches the editor's control plane one-way")

        // Chapter Two moves first: a binder change, no text touched.
        let parent = Self.parentId(of: two.id, in: store.manifest.structure)
        try await store.moveStructureItem(id: two.id, toParentId: parent, atIndex: 0)

        let renumbered = await pumpUntil(deadline: 10) {
            listing.rows.map(\.figureId) == [Self.debt.id, Self.cash.id]
        }
        XCTAssertTrue(renumbered, "the listing follows the binder: \(listing.rows)")
        XCTAssertEqual(listing.rows.map(\.number), ["Table 1", "Table 2"])
        XCTAssertEqual(listing.rows.first?.pieceOfLine, two.id)
    }

    /// The registry changing alone (a figure made elsewhere) re-lists with
    /// no text moving: the new figure is unused.
    func test_aNewRecordIsListedUnusedWithNoRebuild() async throws {
        let url = try await ProjectFactory.createNovelProject(
            named: "Figures-\(UUID().uuidString.prefix(6))", in: temp.url)
        let store = try await ProjectStore.load(from: url)
        await store.wordCountPopulationTask?.value
        let ds = try await DocumentStore.open(url: url)
        store.documentStore = ds
        ds.projectStore = store
        documentStores.append(ds)

        let listing = FigureListingModel()
        let root = Color.clear.modifier(ReferenceIndexWiring(
            url: url, store: store, documentStore: ds, referenceIndex: ReferenceIndexHost(),
            figureListing: listing, control: EditorControl(), window: nil))
        windows.append(TestWindow.mount(AnyView(root), size: CGSize(width: 200, height: 200)))

        store.manifest.figures = [Self.cash]
        let listed = await pumpUntil(deadline: 10) { listing.rows.map(\.figureId) == [Self.cash.id] }
        XCTAssertTrue(listed, "the registry's change reaches the listing")
        XCTAssertEqual(listing.rows.first?.number, "—")
    }

    private static func parentId(of id: String, in items: [StructureItem]) -> String? {
        func walk(_ items: [StructureItem], parent: String?) -> String?? {
            for item in items {
                if item.id == id { return .some(parent) }
                if let found = walk(item.children ?? [], parent: item.id) { return found }
            }
            return nil
        }
        return walk(items, parent: nil) ?? nil
    }
}
