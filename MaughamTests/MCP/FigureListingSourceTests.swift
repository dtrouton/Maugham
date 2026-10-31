import XCTest
import MaughamCore
@testable import Maugham

/// Report plan 9b Task 6: the figure listing with no project window.
@MainActor
final class FigureListingSourceTests: XCTestCase {

    private let cash = FigureRecord(id: "fig-0a0a0a0a", name: "cash", kind: .table,
                                    piece: nil, path: "figures/cash.csv")
    private let spare = FigureRecord(id: "fig-3d3d3d3d", name: "spare", kind: .table,
                                     piece: nil, path: "figures/spare.csv")

    private struct Fixture {
        let store: ProjectStore
        let ds: DocumentStore
        let chapterURL: URL
    }

    private func makeProject() async throws -> Fixture {
        let tmp = TestTemp.root.appendingPathComponent("FigSrc-\(UUID().uuidString)")
        let fm = FileManager.default
        try fm.createDirectory(at: tmp.appendingPathComponent("manuscript"), withIntermediateDirectories: true)
        let one = "Opening.\n\n![Cash flow](../figures/cash.csv){#tbl:cash}\n"
        let two = "Later.\n\n![Again](../figures/cash.csv)\n"
        try one.write(to: tmp.appendingPathComponent("manuscript/c1.md"), atomically: true, encoding: .utf8)
        try two.write(to: tmp.appendingPathComponent("manuscript/c2.md"), atomically: true, encoding: .utf8)
        let structure = [
            StructureItem(id: "doc-c1", title: "One", type: .document, path: "manuscript/c1.md"),
            StructureItem(id: "doc-c2", title: "Two", type: .document, path: "manuscript/c2.md"),
        ]
        var manifest = ProjectManifest(type: .novel, title: "T", author: "A", created: Date(),
                                       modified: Date(), structure: structure, research: [])
        manifest.figures = [cash, spare]
        try ProjectManifest.makeEncoder().encode(manifest)
            .write(to: tmp.appendingPathComponent(ProjectManifest.fileName))
        let store = try await ProjectStore.load(from: tmp)
        let ds = try await DocumentStore.open(url: tmp)
        store.documentStore = ds
        // Load each piece once so its op log exists (a real piece always has
        // one); the documents are not registered, so the pieces are closed.
        for name in ["c1", "c2"] {
            _ = try await Document.load(url: tmp.appendingPathComponent("manuscript/\(name).md"),
                                        device: "test", session: "s", presenter: nil)
        }
        return Fixture(store: store, ds: ds, chapterURL: tmp.appendingPathComponent("manuscript/c1.md"))
    }

    func test_aClosedProjectListsNumberedUsedAndUnusedFigures() async throws {
        let f = try await makeProject()
        defer { Task { await f.ds.close() } }
        let rows = await FigureListingSource.rows(store: f.store)
        XCTAssertEqual(rows.map(\.name), ["cash", "spare"])
        XCTAssertEqual(rows[0].number, "Table 1")
        XCTAssertEqual(rows[0].caption, "Cash flow")
        XCTAssertEqual(rows[0].usedIn.count, 2)
        XCTAssertTrue(rows[1].isUnused)
        XCTAssertEqual(rows[1].number, "—")
    }

    func test_textTypedIntoAnOpenUnsavedDocumentChangesTheCaption() async throws {
        let f = try await makeProject()
        defer { Task { await f.ds.close() } }
        let doc = try await Document.load(url: f.chapterURL, device: "test", session: "s", presenter: nil)
        f.ds.register(document: doc, for: "manuscript/c1.md")
        doc.setFullText("Opening.\n\n![Typed caption](../figures/cash.csv){#tbl:cash}\n")
        let rows = await FigureListingSource.rows(store: f.store)
        XCTAssertEqual(rows.first?.caption, "Typed caption")
    }

    func test_noDocumentStoreListsNothing() async throws {
        let f = try await makeProject()
        defer { Task { await f.ds.close() } }
        f.store.documentStore = nil
        let rows = await FigureListingSource.rows(store: f.store)
        XCTAssertEqual(rows, [])
    }
}
