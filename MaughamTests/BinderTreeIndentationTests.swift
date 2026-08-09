import XCTest
import AppKit
import SwiftUI
import MaughamCore
@testable import Maugham

/// **The binder trees read as one staircase** (smoke, 2026-08-08: *"the tree
/// indentation is confusing. When I expand items under a chapter or piece are
/// further left than the parent"*).
///
/// Three hosts draw a tree — `BinderView`, `CollectionPiecesPane`,
/// `SceneNavigatorPane` — and a writer sees one of them, so nothing here can be
/// checked by comparing two files. It has to be measured on a mounted window,
/// and this suite is the only place that is done.
///
/// **What is measured, and why it is pixels.** A SwiftUI row draws its label
/// into a `CellHostingView`; there is no `NSTextField` and no accessibility tree
/// in this host (`BinderProjectRowTests` measured both), so a row's content has
/// no frame to read. What a writer sees is ink, so ink is what is asked for:
/// `contentInk(ofRow:)` renders the row's own cell view and returns the leftmost
/// column that differs from its background, in the outline's coordinates. The
/// disclosure triangle is drawn by `NSOutlineView` in the indentation gutter to
/// the LEFT of that cell (measured: chevron at x=12, cell at x=25 for a
/// top-level row), so it is outside the measurement — which is what makes
/// "a chevron'd row and a leaf row start their content at the same x" an
/// assertable claim rather than a tautology.
///
/// **The three facts this suite pins**, each of which has been wrong in shipped
/// code:
///
/// 1. *A child's content is strictly right of its parent's.* Broken in
///    `CollectionPiecesPane` from stage-2a Task 6 until this fix: the 14pt
///    `ProjectRowLabel.childIndent` was applied to the piece ROW rather than to
///    the `DisclosureGroup`, and a `List` propagates a modifier on the group to
///    the rows it unfolds to but not one on its label. The fold's children got
///    the outline's 12pt level indent and lost the parent's 14pt inset — a net
///    2pt to the LEFT of the row they belong to.
/// 2. *Siblings align whether or not they carry a chevron.* `NSOutlineView`
///    already reserves the gutter for every row at a level; the assertion exists
///    so that a future "fix" that pads leaf rows by hand goes red instead of
///    breaking the alignment it means to create.
/// 3. *Depth steps once per level.* `BinderView.outline` applies the inset at
///    the top level ONLY, because a `DisclosureGroup` already indents its own
///    children — adding it per level compounds into a staircase. That is the
///    historical bug the doc comment there records, and this is the measurement
///    behind it.
@MainActor
final class BinderTreeIndentationTests: XCTestCase {

    private var temp: TempDirectory!
    private var windows: [NSWindow] = []
    private var documentStores: [DocumentStore] = []

    /// How much of the outline's 12pt per-level step a child must actually
    /// gain to count as indented. Deliberately well under the step itself,
    /// because the rows being compared draw different glyphs and a glyph's left
    /// side bearing is worth a point or two (a folder and a document icon
    /// measured 2pt apart on macOS 26.5) — this suite is about the layout, not
    /// the icon set. It is still far above the defect it was written for, which
    /// put a child FOUR points to the left of its parent.
    private let minimumStep: CGFloat = 6

    override func setUp() async throws {
        temp = TempDirectory()
    }

    override func tearDown() async throws {
        for window in windows { window.contentView = NSView(frame: .zero) }
        pump(0.05)
        windows.removeAll()
        for ds in documentStores { await ds.close() }
        documentStores.removeAll()
        temp.cleanup()
        temp = nil
    }

    // MARK: - A child sits right of its parent

    /// **The reported bug, in the tree the writer reported it from.** A
    /// Collection piece unfolds to the research in its own folder; those rows
    /// belong to the piece above them and have to look like it.
    func test_aCollectionPiecesFoldChildSitsRightOfThePieceRow() async throws {
        let store = try await collection()
        let piece = try await store.addLoosePiece(title: "Alpha", mode: .prose)
        let note = try await store.addPieceResearchNote(
            pieceId: piece.id, title: "Alpha's Note")

        let (window, probe) = try await hostCollection(store: store)
        let outline = try XCTUnwrap(outlineView(in: window))
        try expandRow(1, in: outline)

        try await assertIdentity(row: 1, is: .item(piece.id), in: outline, probe: probe)
        try await assertIdentity(row: 2, is: .research(note.id), in: outline, probe: probe)

        let parent = try contentInk(ofRow: 1, in: outline)
        let child = try contentInk(ofRow: 2, in: outline)
        XCTAssertGreaterThan(
            child, parent + minimumStep,
            "a piece's research is drawn UNDER that piece, so it has to start "
            + "right of it — measured parent \(parent), child \(child)")
    }

    /// The same claim in the other host. A novel chapter's fold is links rather
    /// than containment, and it is drawn by the same `BinderPieceFold` — but
    /// mounted by a different file, with its own inset, so a fix in one host
    /// says nothing about the other.
    func test_aNovelChaptersFoldChildSitsRightOfTheChapterRow() async throws {
        let store = try await novel()
        let chapter = try XCTUnwrap(store.manifest.structure.first)
        let note = try await store.addResearchTextNote(parentId: nil, title: "Tides")
        try await store.linkResearch(researchId: note.id, toDocumentId: chapter.id)

        let (window, probe) = try await hostBinder(store: store)
        let outline = try XCTUnwrap(outlineView(in: window))
        try expandRow(1, in: outline)

        try await assertIdentity(row: 1, is: .item(chapter.id), in: outline, probe: probe)
        try await assertIdentity(row: 2, is: .research(note.id), in: outline, probe: probe)

        let parent = try contentInk(ofRow: 1, in: outline)
        let child = try contentInk(ofRow: 2, in: outline)
        XCTAssertGreaterThan(child, parent + minimumStep,
                             "measured parent \(parent), child \(child)")
    }

    /// **A group inside a fold steps again.** The fold's own rows are one level
    /// down from the piece; a group in a Collection piece's folder is a group of
    /// that piece's research and expands, so its children are two. Nothing in
    /// the tree may flatten on the way down.
    func test_aGroupInsideAPiecesFoldStepsRightAgain() async throws {
        let store = try await collection()
        let piece = try await store.addLoosePiece(title: "Alpha", mode: .prose)
        let group = try await store.addResearchItem(
            parentId: nil, title: "Sources", kind: nil)
        let child = try await store.addResearchTextNote(
            parentId: group.id, title: "A Clipping")
        try await store.moveResearchItems(ids: [group.id], to: .piece(piece.id))

        let (window, probe) = try await hostCollection(store: store)
        let outline = try XCTUnwrap(outlineView(in: window))
        try expandRow(1, in: outline)   // the piece
        try expandRow(2, in: outline)   // the group inside its fold

        try await assertIdentity(row: 1, is: .item(piece.id), in: outline, probe: probe)
        try await assertIdentity(row: 2, is: .research(group.id), in: outline, probe: probe)
        try await assertIdentity(row: 3, is: .research(child.id), in: outline, probe: probe)

        let piece_ = try contentInk(ofRow: 1, in: outline)
        let group_ = try contentInk(ofRow: 2, in: outline)
        let leaf = try contentInk(ofRow: 3, in: outline)
        XCTAssertGreaterThan(group_, piece_ + minimumStep,
                             "the group is inside the piece's fold")
        XCTAssertGreaterThan(leaf, group_ + minimumStep,
                             "and its own note is inside the group — measured "
                             + "\(piece_), \(group_), \(leaf)")
    }

    // MARK: - Siblings align, chevron or not

    /// **A leaf row and a folded row at the same level start at the same x.**
    /// `NSOutlineView` reserves the disclosure gutter for every row at a level,
    /// so this holds without anything in the app doing it — and it is asserted
    /// because the obvious hand-fix for a misaligned tree is to pad the rows
    /// that have no triangle, which would break exactly this.
    func test_aPieceWithAFoldAndOneWithoutStartAtTheSameX() async throws {
        let store = try await collection()
        let alpha = try await store.addLoosePiece(title: "Alpha", mode: .prose)
        _ = try await store.addPieceResearchNote(pieceId: alpha.id, title: "Alpha's Note")
        let bravo = try await store.addLoosePiece(title: "Bravo", mode: .prose)

        let (window, probe) = try await hostCollection(store: store)
        let outline = try XCTUnwrap(outlineView(in: window))

        try await assertIdentity(row: 1, is: .item(alpha.id), in: outline, probe: probe)
        try await assertIdentity(row: 2, is: .item(bravo.id), in: outline, probe: probe)
        XCTAssertTrue(try isExpandable(row: 1, in: outline),
                      "precondition: Alpha carries a chevron")
        XCTAssertFalse(try isExpandable(row: 2, in: outline),
                       "precondition: Bravo does not")

        let withChevron = try contentInk(ofRow: 1, in: outline)
        let without = try contentInk(ofRow: 2, in: outline)
        XCTAssertEqual(withChevron, without, accuracy: 1,
                       "two pieces are siblings whatever their research; the "
                       + "triangle lives in the gutter and must not move the "
                       + "row — measured \(withChevron) and \(without)")
    }

    /// The same claim in the manuscript tree — and between two rows drawn with
    /// the SAME glyph, so what is compared is the layout and nothing else. Two
    /// chapters, one of which has research linked to it and therefore a
    /// chevron.
    ///
    /// **A group row is deliberately not the comparison here.** It is a sibling
    /// at the same level and it does line up, but its folder glyph has a
    /// different left side bearing from a document's — measured 1.5pt on macOS
    /// 26.5 — and a test that has to carry that tolerance is measuring the icon
    /// set as much as the tree.
    func test_aChapterWithAFoldAndOneWithoutStartAtTheSameX() async throws {
        let store = try await novel()
        let linked = try XCTUnwrap(store.manifest.structure.first)
        let plain = try await store.addStructureItem(
            parentId: nil, title: "Chapter Two", kind: .document(extension: "md"))
        let note = try await store.addResearchTextNote(parentId: nil, title: "Tides")
        try await store.linkResearch(researchId: note.id, toDocumentId: linked.id)

        let (window, probe) = try await hostBinder(store: store)
        let outline = try XCTUnwrap(outlineView(in: window))

        try await assertIdentity(row: 1, is: .item(linked.id), in: outline, probe: probe)
        try await assertIdentity(row: 2, is: .item(plain.id), in: outline, probe: probe)
        XCTAssertTrue(try isExpandable(row: 1, in: outline),
                      "precondition: the linked chapter carries a chevron")
        XCTAssertFalse(try isExpandable(row: 2, in: outline),
                       "precondition: the other does not")

        XCTAssertEqual(try contentInk(ofRow: 1, in: outline),
                       try contentInk(ofRow: 2, in: outline), accuracy: 1,
                       "two chapters are siblings whatever is linked to them")
    }

    // MARK: - One step per level, never a staircase

    /// **The historical bug, pinned.** `ProjectRowLabel.childIndent` is applied
    /// at the top level only: a `DisclosureGroup`'s children are already
    /// indented under it, and a `List` propagates the group's own inset down to
    /// them, so re-applying it as the recursion descends compounds. Three levels
    /// deep is where that first becomes visible, and each step here must be the
    /// outline's own — not the outline's plus another inset.
    func test_threeLevelsOfGroupsStepOnceEachAndNeverCompound() async throws {
        let store = try await novel()
        let outer = try await store.addStructureItem(
            parentId: nil, title: "Part One", kind: .group)
        let inner = try await store.addStructureItem(
            parentId: outer.id, title: "Inner", kind: .group)
        let leaf = try await store.addStructureItem(
            parentId: inner.id, title: "Deep Chapter", kind: .document(extension: "md"))

        let (window, probe) = try await hostBinder(store: store)
        let outline = try XCTUnwrap(outlineView(in: window))
        let outerRow = store.manifest.structure.count
        try expandRow(outerRow, in: outline)
        try expandRow(outerRow + 1, in: outline)

        try await assertIdentity(row: outerRow, is: .item(outer.id),
                                 in: outline, probe: probe)
        try await assertIdentity(row: outerRow + 1, is: .item(inner.id),
                                 in: outline, probe: probe)
        try await assertIdentity(row: outerRow + 2, is: .item(leaf.id),
                                 in: outline, probe: probe)

        let step = outline.indentationPerLevel
        let a = try contentInk(ofRow: outerRow, in: outline)
        let b = try contentInk(ofRow: outerRow + 1, in: outline)
        let c = try contentInk(ofRow: outerRow + 2, in: outline)
        XCTAssertEqual(b - a, step, accuracy: 2,
                       "one level, one step — measured \(a) → \(b)")
        XCTAssertEqual(c - b, step, accuracy: 2,
                       "and the third level must not have gained the inset a "
                       + "second time — measured \(b) → \(c)")
    }

    /// **And the top level is inset under the project row**, which is what
    /// `ProjectRowLabel.childIndent` is for: the row naming the project is the
    /// head of the tree, and everything else hangs below it. Without this the
    /// tests above would all pass with the inset deleted outright.
    func test_theTopLevelIsInsetUnderTheProjectRow() async throws {
        let store = try await collection()
        let piece = try await store.addLoosePiece(title: "Alpha", mode: .prose)

        let (window, probe) = try await hostCollection(store: store)
        let outline = try XCTUnwrap(outlineView(in: window))
        try await assertIdentity(row: 0, is: .project, in: outline, probe: probe)
        try await assertIdentity(row: 1, is: .item(piece.id), in: outline, probe: probe)

        XCTAssertGreaterThan(
            try contentInk(ofRow: 1, in: outline),
            try contentInk(ofRow: 0, in: outline) + minimumStep,
            "a piece is below the project in the hierarchy and has to read "
            + "that way")
    }

    // MARK: - Measuring

    /// The leftmost x, in the outline's coordinates, at which row `row` draws
    /// anything — its own cell only, so the disclosure triangle in the gutter
    /// beside it is excluded.
    ///
    /// Nothing may be selected while this runs: a selected row draws a rounded
    /// capsule whose left edge is ink of a kind this measurement is not about.
    private func contentInk(ofRow row: Int, in outline: NSOutlineView) throws -> CGFloat {
        outline.deselectAll(nil)
        pump(0.15)
        let view = try XCTUnwrap(outline.view(atColumn: 0, row: row, makeIfNecessary: true),
                                 "no cell view for row \(row)")
        let offset = try XCTUnwrap(leftmostInk(in: view),
                                   "row \(row) drew nothing at all")
        return outline.convert(view.bounds, from: view).minX + offset
    }

    /// Leftmost column with ink, in `view`'s own coordinates. The background is
    /// sampled from the view's own left edge, which is inside the row's
    /// indentation and never carries content.
    private func leftmostInk(in view: NSView) -> CGFloat? {
        guard view.bounds.width > 1, view.bounds.height > 1,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)
        else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        let width = rep.pixelsWide
        let height = rep.pixelsHigh
        guard width > 0, height > 0, let background = rep.colorAt(x: 0, y: height / 2)
        else { return nil }
        let scale = CGFloat(width) / view.bounds.width
        for x in 0..<width {
            for y in 0..<height where rep.colorAt(x: x, y: y).map({
                differs($0, from: background)
            }) == true {
                return CGFloat(x) / scale
            }
        }
        return nil
    }

    private func differs(_ a: NSColor, from b: NSColor) -> Bool {
        guard let x = a.usingColorSpace(.deviceRGB),
              let y = b.usingColorSpace(.deviceRGB) else { return false }
        return abs(x.redComponent - y.redComponent) > 0.06
            || abs(x.greenComponent - y.greenComponent) > 0.06
            || abs(x.blueComponent - y.blueComponent) > 0.06
            || abs(x.alphaComponent - y.alphaComponent) > 0.06
    }

    /// **Which row is which, asked of the row itself.** A mounted SwiftUI row
    /// will not give up the string it draws (`BinderProjectRowTests` measured
    /// that), so a row is named here the way every mounted binder test names
    /// one: by the subject selecting it writes. The selection is cleared again
    /// by `contentInk`, which the measurement requires anyway.
    private func assertIdentity(row: Int, is subject: BinderSubject,
                                in outline: NSOutlineView,
                                probe: BinderSubjectProbe,
                                file: StaticString = #filePath,
                                line: UInt = #line) async throws {
        outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        _ = await pumpUntil(deadline: 5) { probe.subject == subject }
        XCTAssertEqual(probe.subject, subject,
                       "row \(row) is not the row this test is about",
                       file: file, line: line)
    }

    private func expandRow(_ row: Int, in outline: NSOutlineView) throws {
        let item = try XCTUnwrap(outline.item(atRow: row),
                                 "no row \(row) in a list of \(outline.numberOfRows)")
        XCTAssertTrue(outline.isExpandable(item),
                      "row \(row) has no disclosure triangle to open")
        outline.expandItem(item)
        pump(0.2)
    }

    private func isExpandable(row: Int, in outline: NSOutlineView) throws -> Bool {
        let item = try XCTUnwrap(outline.item(atRow: row),
                                 "no row \(row) in a list of \(outline.numberOfRows)")
        return outline.isExpandable(item)
    }

    // MARK: - Fixtures

    private func novel() async throws -> ProjectStore {
        let url = try await ProjectFactory.createNovelProject(
            named: "Novel-\(UUID().uuidString.prefix(6))", in: temp.url)
        return try await furnish(try await ProjectStore.load(from: url))
    }

    private func collection() async throws -> ProjectStore {
        let url = try await ProjectFactory.createCollectionProject(
            named: "Collection-\(UUID().uuidString.prefix(6))", in: temp.url)
        return try await furnish(try await ProjectStore.load(from: url))
    }

    private func furnish(_ store: ProjectStore) async throws -> ProjectStore {
        let ds = try await DocumentStore.open(url: store.url)
        store.documentStore = ds
        documentStores.append(ds)
        await store.wordCountPopulationTask?.value
        return store
    }

    // MARK: - Hosting

    private func hostBinder(
        store: ProjectStore
    ) async throws -> (NSWindow, BinderSubjectProbe) {
        let probe = BinderSubjectProbe()
        let window = try await mount(AnyView(
            IndentBinderProbeView(store: store, probe: probe)))
        return (window, probe)
    }

    private func hostCollection(
        store: ProjectStore
    ) async throws -> (NSWindow, BinderSubjectProbe) {
        let probe = BinderSubjectProbe()
        let window = try await mount(AnyView(
            IndentCollectionProbeView(store: store, probe: probe)))
        return (window, probe)
    }

    private func mount(_ root: AnyView) async throws -> NSWindow {
        let frame = CGRect(x: 0, y: 0, width: 320, height: 900)
        let hosting = NSHostingView(rootView: root)
        hosting.frame = frame
        let window = SilentTestWindow(contentRect: frame, styleMask: [.titled],
                                      backing: .buffered, defer: false)
        window.contentView = hosting
        window.orderFront(nil)
        hosting.layoutSubtreeIfNeeded()
        windows.append(window)
        await pumpUntil(deadline: 5) { self.outlineView(in: window) != nil }
        // The palette section loads its cards from disk once per manifest
        // change, so the rows it contributes arrive a turn after the list does.
        pump(0.2)
        return window
    }

    private func outlineView(in window: NSWindow) -> NSOutlineView? {
        guard let root = window.contentView else { return nil }
        var found: [NSOutlineView] = []
        collect(NSOutlineView.self, in: root, into: &found)
        return found.first
    }

    private func collect<T: NSView>(_ type: T.Type, in view: NSView, into out: inout [T]) {
        if let hit = view as? T { out.append(hit) }
        for sub in view.subviews { collect(type, in: sub, into: &out) }
    }
}

// MARK: - Probes

@MainActor
private struct IndentBinderProbeView: View {
    let store: ProjectStore
    let probe: BinderSubjectProbe

    var body: some View {
        BinderView(store: store,
                   selectedSubject: Binding(get: { probe.subject },
                                            set: { probe.subject = $0 }))
    }
}

@MainActor
private struct IndentCollectionProbeView: View {
    let store: ProjectStore
    let probe: BinderSubjectProbe
    @State private var renaming: String?

    var body: some View {
        CollectionPiecesPane(
            store: store,
            selectedSubject: Binding(get: { probe.subject },
                                     set: { probe.subject = $0 }),
            renamingItemId: $renaming)
    }
}
