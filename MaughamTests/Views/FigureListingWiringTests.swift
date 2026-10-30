import XCTest
import SwiftUI
import MaughamCore
@testable import Maugham

/// **The window's figure listing with no editor mounted** (report plan 8a
/// Task 2): `ReferenceIndexWiring` — the window's own modifier, as
/// `ProjectWindow` mounts it, handed its real window — attaches the window's
/// `ReferenceIndexHost` and carries the project's edges, so the Figures
/// listing follows the binder, another device's sync and the editor going
/// away in Plan persona, whose centre is the canvas and mounts no
/// `EditorHost`. Driven through the stores and the probe's own state; no
/// control is pressed (tripwire 33).
@MainActor
final class FigureListingWiringTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        // One test mounts `EditorHost`, which styles through production typography.
        FontWarmup.ensure()
    }

    private var temp: TempDirectory!
    private var windows: [NSWindow] = []
    private var documentStores: [DocumentStore] = []
    private var defaultsSuites: [String] = []

    override func setUp() async throws { temp = TempDirectory() }

    override func tearDown() async throws {
        for window in windows { window.contentView = NSView(frame: .zero); window.close() }
        windows.removeAll()
        for ds in documentStores { await ds.close() }
        documentStores.removeAll()
        for suite in defaultsSuites { UserDefaults.standard.removePersistentDomain(forName: suite) }
        defaultsSuites.removeAll()
        temp.cleanup()
        temp = nil
    }

    private static let cash = FigureRecord(id: "fig-0a0a0a0a", name: "cash", kind: .table, piece: nil,
                                           path: "figures/cash.csv")
    private static let debt = FigureRecord(id: "fig-1b1b1b1b", name: "debt", kind: .table, piece: nil,
                                           path: "figures/debt.csv")

    // MARK: - The probe: the window's wiring, an optional editor, a real window

    @Observable
    @MainActor
    final class Box {
        var store: ProjectStore?
        var documentStore: DocumentStore?
        /// The editor's item, or nil for Plan's centre (no `EditorHost`).
        var editingItemId: String?
    }

    private struct Probe: View {
        let url: URL
        let box: Box
        let host: ReferenceIndexHost
        let listing: FigureListingModel
        let control: EditorControl
        /// False hands the wiring no window, so it hears no project event:
        /// a test that pins another edge alone.
        let hearsProjectEvents: Bool
        @State private var window: NSWindow?

        var body: some View {
            ZStack {
                if let store = box.store, let ds = box.documentStore, let item = box.editingItemId {
                    EditorHost(store: store, documentStore: ds, selectedItemId: item,
                               control: control, referenceIndex: host, figureListing: listing)
                } else {
                    Color.clear
                }
            }
            .modifier(ReferenceIndexWiring(
                url: url, store: box.store, documentStore: box.documentStore,
                referenceIndex: host, figureListing: listing, control: control,
                window: hearsProjectEvents ? window : nil))
            .background(WindowAccessor(window: $window))
        }
    }

    private struct Mounted {
        let url: URL
        let store: ProjectStore
        let ds: DocumentStore
        let chapters: [StructureItem]
        let box: Box
        let host: ReferenceIndexHost
        let listing: FigureListingModel
        let control: EditorControl
    }

    /// A novel of `chapters` chapters, each written with `text(i, chapter)`
    /// and bootstrapped into its op log, closed; the registry holds `records`.
    /// Mounted with no editor unless `editing` names a chapter index.
    private func mount(chapters count: Int, records: [FigureRecord], editing: Int? = nil,
                       hearsProjectEvents: Bool = true,
                       text: (Int, StructureItem) throws -> String) async throws -> Mounted {
        let url = try await ProjectFactory.createNovelProject(
            named: "Figures-\(UUID().uuidString.prefix(6))", in: temp.url)
        let store = try await ProjectStore.load(from: url)
        for i in 1..<count {
            _ = try await store.addStructureItem(parentId: nil, title: "Chapter \(i + 1)",
                                                 kind: .document(.markdown))
        }
        let chapters = ProjectStore.collectDocuments(in: store.manifest.structure)
        XCTAssertEqual(chapters.count, count, "fixture precondition: the chapters asked for")
        // Written before anything opens it, then bootstrapped into its op log
        // and closed (ADR 0018's derived direction).
        for (i, chapter) in chapters.enumerated() {
            let path = try XCTUnwrap(chapter.path)
            try text(i, chapter).write(to: url.appendingPathComponent(path), atomically: true,
                                       encoding: .utf8)
            let doc = try await Document.load(url: url.appendingPathComponent(path), actor: .author,
                                              session: "s", presenter: nil)
            await doc.close()
        }
        store.manifest.figures = records
        await store.wordCountPopulationTask?.value
        let ds = try await DocumentStore.open(url: url)
        store.documentStore = ds
        ds.projectStore = store
        documentStores.append(ds)

        let box = Box()
        box.store = store
        box.documentStore = ds
        box.editingItemId = editing.map { chapters[$0].id }
        let host = ReferenceIndexHost(), listing = FigureListingModel(), control = EditorControl()
        let suite = "figure-listing-wiring-\(UUID().uuidString)"
        defaultsSuites.append(suite)
        let preferences = UserPreferences(defaults: UserDefaults(suiteName: suite)!)
        let root = Probe(url: url, box: box, host: host, listing: listing, control: control,
                         hearsProjectEvents: hearsProjectEvents)
            .environment(preferences)
        windows.append(TestWindow.mount(AnyView(root), size: CGSize(width: 600, height: 400)))
        return Mounted(url: url, store: store, ds: ds, chapters: chapters, box: box, host: host,
                       listing: listing, control: control)
    }

    /// A chapter's figure line for `record`, written from where the chapter sits.
    private static func line(_ record: FigureRecord, in chapter: StructureItem) throws -> String {
        let path = try XCTUnwrap(chapter.path)
        let climb = String(repeating: "../", count: path.split(separator: "/").count - 1)
        return "![\(record.name)](\(climb)\(record.path))"
    }

    // MARK: - Tests

    func test_withNoEditorMounted_aStructureChangeReNumbersTheListing() async throws {
        let m = try await mount(chapters: 2, records: [Self.debt, Self.cash]) { i, chapter in
            "Prose.\n\n\(try Self.line(i == 0 ? Self.cash : Self.debt, in: chapter))\n"
        }
        let one = m.chapters[0], two = m.chapters[1]

        // Waits on the numbers, not the order: before any build both are
        // unused, and "cash" sorts before "debt" by name anyway.
        let numbered = await pumpUntil(deadline: 10) {
            m.listing.rows.map(\.number) == ["Table 1", "Table 2"]
        }
        XCTAssertTrue(numbered, "the first build numbers both: \(m.listing.rows)")
        XCTAssertEqual(m.listing.rows.map(\.figureId), [Self.cash.id, Self.debt.id], "in chapter order")
        XCTAssertEqual(m.listing.rows.map(\.pieceOfLine), [one.id, two.id])
        XCTAssertEqual(m.listing.row(forFigureId: Self.debt.id)?.number, "Table 2")
        XCTAssertGreaterThan(m.control.referenceIndexVersion, 0,
                             "the version reaches the editor's control plane one-way")

        // Chapter Two moves first: a binder change, no text touched.
        let parent = Self.parentId(of: two.id, in: m.store.manifest.structure)
        try await m.store.moveStructureItem(id: two.id, toParentId: parent, atIndex: 0)

        let renumbered = await pumpUntil(deadline: 10) {
            m.listing.rows.map(\.figureId) == [Self.debt.id, Self.cash.id]
        }
        XCTAssertTrue(renumbered, "the listing follows the binder: \(m.listing.rows)")
        XCTAssertEqual(m.listing.rows.map(\.number), ["Table 1", "Table 2"])
        XCTAssertEqual(m.listing.rows.first?.pieceOfLine, two.id)
        XCTAssertEqual(m.listing.row(forFigureId: Self.debt.id)?.number, "Table 1")
    }

    /// The registry changing alone (a figure made elsewhere) re-lists with
    /// no text moving: the new figure is unused.
    func test_aNewRecordIsListedUnusedWithNoRebuild() async throws {
        let m = try await mount(chapters: 1, records: []) { _, _ in "Prose.\n" }
        let built = await pumpUntil(deadline: 10) { m.host.index.version > 0 }
        XCTAssertTrue(built, "precondition: the first build landed")
        m.store.manifest.figures = [Self.cash]
        let listed = await pumpUntil(deadline: 10) { m.listing.rows.map(\.figureId) == [Self.cash.id] }
        XCTAssertTrue(listed, "the registry's change reaches the listing")
        XCTAssertEqual(m.listing.rows.first?.number, "—")
    }

    /// Another device's sync of a closed piece (`maughamAnnotationsChanged`,
    /// delivered to the probe's real window) re-reads that piece from its op
    /// log, with no editor mounted.
    func test_aClosedPiecesSyncReNumbersTheListing() async throws {
        let m = try await mount(chapters: 1, records: [Self.cash]) { _, _ in "Prose.\n" }
        let built = await pumpUntil(deadline: 10) { m.host.index.version > 0 && !m.listing.rows.isEmpty }
        XCTAssertTrue(built, "precondition: the first build landed")
        XCTAssertEqual(m.listing.rows.first?.number, "—")

        // The piece's op log moves under the window, as a sync would move it.
        let chapter = m.chapters[0]
        let path = try XCTUnwrap(chapter.path)
        let doc = try await Document.load(url: m.url.appendingPathComponent(path), actor: .author,
                                          session: "s", presenter: nil)
        try await doc.setFullText("Prose.\n\n\(try Self.line(Self.cash, in: chapter))\n")
        await doc.close()
        MaughamEvent.postAnnotationsChanged(docId: chapter.id, projectURL: m.url)

        let synced = await pumpUntil(deadline: 10) { m.listing.rows.first?.number == "Table 1" }
        XCTAssertTrue(synced, "the sync edge re-read the piece: \(m.listing.rows)")
    }

    /// Review I1: the window's index outlives the editor, so the editor
    /// leaving (a switch to Plan's canvas) re-reads the piece it closed — a
    /// figure line typed inside the last 350 ms settle is listed. The wiring
    /// hears no project event here: the close's own op-log post would also
    /// re-read the piece, a second later, and this pins the unmount's edge.
    func test_theEditorUnmountingReReadsThePieceItLeft() async throws {
        let m = try await mount(chapters: 1, records: [Self.cash], editing: 0,
                                hearsProjectEvents: false) { _, _ in "Prose.\n" }
        let chapter = m.chapters[0]
        let path = try XCTUnwrap(chapter.path)
        let opened = await pumpUntil(deadline: 10) {
            m.ds.document(for: path) != nil && m.host.index.version > 0
                && Self.textView(in: self.windows.last!) != nil
        }
        XCTAssertTrue(opened, "precondition: the editor opened the chapter and the index built")
        let textView = try XCTUnwrap(Self.textView(in: try XCTUnwrap(windows.last)),
                                     "precondition: the editor is mounted")
        let settled = await pumpUntil(deadline: 10) { textView.string.hasPrefix("Prose.") }
        XCTAssertTrue(settled, "precondition: the chapter's text is on screen")

        // The writer types a figure line and leaves at once, inside the 350 ms
        // settle that would have reported it: the probe's centre becomes Plan's.
        let end = NSRange(location: (textView.string as NSString).length, length: 0)
        textView.insertText("\n\(try Self.line(Self.cash, in: chapter))\n", replacementRange: end)
        m.box.editingItemId = nil

        let listed = await pumpUntil(deadline: 10) { m.listing.rows.first?.number == "Table 1" }
        XCTAssertTrue(listed, "the piece the editor left is read again: \(m.listing.rows)")
        XCTAssertEqual(m.listing.rows.first?.pieceOfLine, chapter.id)
    }

    /// Report plan 8b Task 3: a figure made unused (Use in document, D8b-1)
    /// is placed from Insert ▸ Existing Figure… — the editor's picker reads
    /// this window's listing — and after the settle the listing, which the
    /// tree's Figures rows read, numbers it.
    func test_aFigurePlacedFromThePickerIsNumberedAfterTheSettle() async throws {
        let m = try await mount(chapters: 1, records: [Self.cash], editing: 0) { _, _ in "Prose.\n" }
        let chapter = m.chapters[0]
        let path = try XCTUnwrap(chapter.path)
        let opened = await pumpUntil(deadline: 10) {
            m.ds.document(for: path) != nil && m.listing.rows.first?.number == "—"
                && (Self.textView(in: self.windows.last!)?.string.hasPrefix("Prose.") ?? false)
        }
        XCTAssertTrue(opened, "precondition: the chapter is on screen and the figure listed unused")
        let textView = try XCTUnwrap(Self.textView(in: try XCTUnwrap(windows.last)))
        let coordinator = try XCTUnwrap(textView.delegate as? EditorCoordinator)
        textView.setSelectedRange(NSRange(location: (textView.string as NSString).length, length: 0))

        let session = try XCTUnwrap(coordinator.insertExistingFigure(), "the picker opened")
        XCTAssertEqual(session.entries.map(\.title), ["— cash (unused)"])
        session.choose(try XCTUnwrap(session.entries.first))
        XCTAssertTrue(textView.string.contains("figures/cash.csv){#tbl:cash}"),
                      "the line was written from the chapter's folder: \(textView.string)")

        let numbered = await pumpUntil(deadline: 10) { m.listing.rows.first?.number == "Table 1" }
        XCTAssertTrue(numbered, "the settle numbered the placed figure: \(m.listing.rows)")
        XCTAssertEqual(m.listing.rows.first?.pieceOfLine, chapter.id)
    }

    /// Review I2: the store going away (the window's close scorches it)
    /// detaches the host and empties the listing.
    func test_theStoreGoingDetachesTheHostAndEmptiesTheListing() async throws {
        let m = try await mount(chapters: 1, records: [Self.cash]) { _, _ in "Prose.\n" }
        let built = await pumpUntil(deadline: 10) { m.host.isAttached && !m.listing.rows.isEmpty }
        XCTAssertTrue(built, "precondition: attached and listed")

        m.box.store = nil
        m.box.documentStore = nil

        let detached = await pumpUntil(deadline: 10) { !m.host.isAttached && m.listing.rows.isEmpty }
        XCTAssertTrue(detached, "no store: the host builds nothing and the listing is empty")
    }

    private static func textView(in window: NSWindow) -> MaughamTextView? {
        func walk(_ view: NSView) -> MaughamTextView? {
            if let hit = view as? MaughamTextView { return hit }
            for sub in view.subviews { if let hit = walk(sub) { return hit } }
            return nil
        }
        return window.contentView.flatMap(walk)
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
