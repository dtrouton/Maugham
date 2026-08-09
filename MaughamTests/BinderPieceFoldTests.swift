import XCTest
import AppKit
import SwiftUI
import MaughamCore
@testable import Maugham

/// **A piece row unfolds to its own research** (shell-finish stage-2a Task 6).
///
/// The milestone gives every persona one left column, so a chapter's or a
/// piece's research has to be reachable from the row it belongs to rather than
/// from a pane the writer switches to. The rule for *which* documents fold is
/// pure and lives in `TreeSectionDerivation.pieceFold` — `TreeSectionDerivationTests`
/// asks it over every project type without a window. What cannot be asked there
/// is whether the tree actually draws a disclosure triangle, whether the row
/// under it is still the piece row, and whether a folded research row reaches
/// the window's subject through a real `List(selection:)`. That is this suite,
/// and it is mounted for the reason `BinderProjectRowTests` records: a row's
/// whole implementation is a label and a `.tag`, and whether the list matches
/// that tag is exactly what a test built from the view's own data cannot see.
///
/// The list a `List(.sidebar)` builds is an `NSOutlineView`, so "has a chevron"
/// is `isExpandable(_:)` and "unfolds" is `expandItem(_:)` — the real
/// disclosure, not a proxy for it.
@MainActor
final class BinderPieceFoldTests: XCTestCase {

    private var temp: TempDirectory!
    private var windows: [NSWindow] = []
    private var documentStores: [DocumentStore] = []

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

    // MARK: - The novel chapter's fold (linked)

    func test_aNovelChapterUnfoldsToItsLinkedResearch() async throws {
        let store = try await novel()
        let chapter = try XCTUnwrap(store.manifest.structure.first)
        let note = try await store.addResearchTextNote(parentId: nil, title: "Tides")
        try await store.linkResearch(researchId: note.id, toDocumentId: chapter.id)

        let (window, probe) = try await hostBinder(store: store)
        let outline = try XCTUnwrap(outlineView(in: window))
        let before = outline.numberOfRows

        try expandRow(1, in: outline)

        XCTAssertEqual(outline.numberOfRows, before + 1,
                       "the chapter unfolds to the one item linked to it")
        await select(row: 2, in: outline,
                     until: { probe.subject == .research(note.id) })
        XCTAssertEqual(probe.subject, .research(note.id),
                       "a folded research row is a subject of the window like "
                       + "any other row in the tree")
    }

    /// **The row under the chevron is still the chapter.** The fold must not
    /// cost the piece row anything it already does, and the first thing it
    /// could cost is being the subject: a `DisclosureGroup` tags the group, not
    /// its label, so a tag left on the label would have made the chapter
    /// unclickable in exactly the projects that have research.
    func test_aFoldedChapterRowIsStillTheChaptersOwnSubject() async throws {
        let store = try await novel()
        let chapter = try XCTUnwrap(store.manifest.structure.first)
        let note = try await store.addResearchTextNote(parentId: nil, title: "Tides")
        try await store.linkResearch(researchId: note.id, toDocumentId: chapter.id)

        let (window, probe) = try await hostBinder(store: store)
        let outline = try XCTUnwrap(outlineView(in: window))

        await select(row: 1, in: outline, until: { probe.subject == .item(chapter.id) })
        XCTAssertEqual(probe.subject, .item(chapter.id))
    }

    /// **No links yet, no chevron.** The fold is still `.linked` — the semantic
    /// is about the routing, not the count — but a triangle onto nothing would
    /// be on every chapter of every novel whose writer has linked nothing.
    func test_aNovelChapterWithNothingLinkedHasNoChevron() async throws {
        let store = try await novel()
        _ = try await store.addResearchTextNote(parentId: nil, title: "Tides")

        let (window, _) = try await hostBinder(store: store)
        let outline = try XCTUnwrap(outlineView(in: window))

        XCTAssertFalse(try isExpandable(row: 1, in: outline),
                       "shared research the chapter is not linked to must not "
                       + "put a chevron on the chapter")
    }

    /// The control for the test above, in the same tree shape: with the note
    /// linked, the very same row IS expandable. Without this, "no chevron"
    /// could be true because nothing in this list ever gets one.
    func test_control_theSameChapterRowGetsAChevronOnceSomethingIsLinked() async throws {
        let store = try await novel()
        let chapter = try XCTUnwrap(store.manifest.structure.first)
        let note = try await store.addResearchTextNote(parentId: nil, title: "Tides")
        try await store.linkResearch(researchId: note.id, toDocumentId: chapter.id)

        let (window, _) = try await hostBinder(store: store)
        let outline = try XCTUnwrap(outlineView(in: window))

        XCTAssertTrue(try isExpandable(row: 1, in: outline))
    }

    /// **A short story's document never folds**, because everything in Research
    /// already IS that document's — folding it under the row would draw every
    /// note in the project twice.
    func test_aShortStoryDocumentHasNoChevron() async throws {
        let store = try await shortStory()
        _ = try await store.addResearchTextNote(parentId: nil, title: "Tides")

        let (window, _) = try await hostBinder(store: store)
        let outline = try XCTUnwrap(outlineView(in: window))

        XCTAssertFalse(try isExpandable(row: 1, in: outline))
    }

    /// **And the screenplay navigator needs no fold work at all** — its script
    /// row is a `sharedOnly` document, so the derivation answers `.none` and
    /// there is nothing for that pane to draw. Asserted rather than assumed:
    /// the navigator is the one tree Task 6 deliberately did not touch, and a
    /// chevron there would mean it needed touching.
    func test_theScreenplayScriptRowHasNoChevron() async throws {
        let store = try await screenplay()
        _ = try await store.addResearchTextNote(parentId: nil, title: "Tides")

        let (window, _) = try await hostNavigator(store: store)
        let outline = try XCTUnwrap(outlineView(in: window))

        XCTAssertFalse(try isExpandable(row: 1, in: outline),
                       "the script row is the screenplay's one document and it "
                       + "folds onto nothing")
    }

    // MARK: - The collection piece's fold (contained)

    func test_aCollectionPieceUnfoldsToTheResearchInItsOwnFolder() async throws {
        let store = try await collection()
        let piece = try await store.addLoosePiece(title: "Alpha", mode: .prose)
        let owned = try await store.addPieceResearchNote(
            pieceId: piece.id, title: "Alpha's Note")
        _ = try await store.addResearchTextNote(parentId: nil, title: "Shared Note")

        let (window, probe) = try await hostCollection(store: store)
        let outline = try XCTUnwrap(outlineView(in: window))
        let before = outline.numberOfRows

        try expandRow(1, in: outline)

        XCTAssertEqual(outline.numberOfRows, before + 1,
                       "the piece unfolds to what is in its own research "
                       + "folder — and not to the shared note beside it")
        await select(row: 2, in: outline,
                     until: { probe.subject == .research(owned.id) })
        XCTAssertEqual(probe.subject, .research(owned.id))
    }

    func test_aCollectionPieceWithNoResearchOfItsOwnHasNoChevron() async throws {
        let store = try await collection()
        _ = try await store.addLoosePiece(title: "Alpha", mode: .prose)
        _ = try await store.addResearchTextNote(parentId: nil, title: "Shared Note")

        let (window, _) = try await hostCollection(store: store)
        let outline = try XCTUnwrap(outlineView(in: window))

        XCTAssertFalse(try isExpandable(row: 1, in: outline),
                       "the project's shared research is not this piece's")
    }

    func test_aFoldedPieceRowIsStillThePiecesOwnSubject() async throws {
        let store = try await collection()
        let piece = try await store.addLoosePiece(title: "Alpha", mode: .prose)
        _ = try await store.addPieceResearchNote(pieceId: piece.id, title: "Alpha's Note")

        let (window, probe) = try await hostCollection(store: store)
        let outline = try XCTUnwrap(outlineView(in: window))

        await select(row: 1, in: outline, until: { probe.subject == .item(piece.id) })
        XCTAssertEqual(probe.subject, .item(piece.id))
    }

    /// **Containment is a tree, so a group inside a piece expands.** This is
    /// the one place the two fold semantics visibly differ: a group in a
    /// piece's own folder holds that piece's research, so it keeps its
    /// disclosure triangle, where a novel chapter's fold is flat.
    func test_aGroupInsideACollectionPiecesFoldExpandsToItsChildren() async throws {
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
        XCTAssertTrue(try isExpandable(row: 2, in: outline),
                      "the group inside the piece keeps its own triangle")
        try expandRow(2, in: outline)   // the group

        await select(row: 3, in: outline, until: { probe.subject == .research(child.id) })
        XCTAssertEqual(probe.subject, .research(child.id),
                       "and its child is a subject like any other row")
    }

    /// **A linked group in a novel chapter's fold does NOT expand.** The fold's
    /// rows are the chapter's `linkedResearchIds`, resolved; a group's children
    /// are not linked to that chapter by anything, so showing them under it
    /// would claim a link nothing recorded.
    func test_aLinkedGroupInANovelChaptersFoldStaysFlat() async throws {
        let store = try await novel()
        let chapter = try XCTUnwrap(store.manifest.structure.first)
        let group = try await store.addResearchItem(
            parentId: nil, title: "Sources", kind: nil)
        _ = try await store.addResearchTextNote(parentId: group.id, title: "A Clipping")
        try await store.linkResearch(researchId: group.id, toDocumentId: chapter.id)

        let (window, _) = try await hostBinder(store: store)
        let outline = try XCTUnwrap(outlineView(in: window))

        try expandRow(1, in: outline)
        XCTAssertFalse(try isExpandable(row: 2, in: outline),
                       "the group is in the fold because it is linked; its "
                       + "children are not, and the fold must not say they are")
    }

    // MARK: - The sweep reaches a fold

    /// Task 2's sweep watches the research ids as well as the structure's, and
    /// a folded row is the first place a *research* subject can be chosen from
    /// a tree. Deleting it must leave the window pointing at the project rather
    /// than at a row that is gone.
    func test_deletingAFoldedResearchItemSweepsTheSubjectToTheProject() async throws {
        let store = try await collection()
        let piece = try await store.addLoosePiece(title: "Alpha", mode: .prose)
        let owned = try await store.addPieceResearchNote(
            pieceId: piece.id, title: "Alpha's Note")

        let (window, probe) = try await hostCollection(store: store, sweeping: true)
        let outline = try XCTUnwrap(outlineView(in: window))
        try expandRow(1, in: outline)
        await select(row: 2, in: outline, until: { probe.subject == .research(owned.id) })
        XCTAssertEqual(probe.subject, .research(owned.id), "precondition")

        try await store.deleteResearchItem(id: owned.id)
        _ = await pumpUntil(deadline: 5) { probe.subject == .project }

        XCTAssertEqual(probe.subject, .project,
                       "the sweep repairs a subject that named a folded row")
    }

    // MARK: - Creating from inside a fold

    /// **A note asked for from inside a fold lands in that fold.** Every verb
    /// on a fold row that names a parent group already routes correctly — the
    /// piece's groups are in `manifest.research` like any other. The hole is a
    /// row at the piece's root, whose parent id is `nil`, and `nil` means the
    /// SHARED root: without the re-route a writer right-clicking inside a
    /// piece's fold and asking for a note would get one in shared research,
    /// nowhere near the piece they asked from.
    func test_aNoteMadeFromACollectionPiecesFoldLandsInThatPiecesFolder() async throws {
        let store = try await collection()
        let piece = try await store.addLoosePiece(title: "Alpha", mode: .prose)
        _ = try await store.addPieceResearchNote(pieceId: piece.id, title: "Alpha's Note")
        let before = store.manifest.research.count

        fold(for: piece.id, in: store).actions.newNote(nil)
        _ = await pumpUntil(deadline: 5) { store.manifest.research.count > before }

        let made = try XCTUnwrap(
            TreeWalk.first(in: store.manifest.research,
                           where: { $0.title == "Untitled Note" }))
        let pieceItem = try XCTUnwrap(
            TreeWalk.find(id: piece.id, in: store.manifest.structure))
        let prefix = try XCTUnwrap(ProjectStore.pieceResearchPrefix(for: pieceItem))
        XCTAssertTrue(made.path?.hasPrefix(prefix) == true,
                      "expected the note under \(prefix), got \(made.path ?? "no path")")
    }

    /// The same rule, the other routing: a novel chapter's fold is links, so a
    /// note made there is a shared note that is linked to the chapter — which
    /// is what puts it in the fold the writer asked from.
    func test_aNoteMadeFromANovelChaptersFoldIsLinkedToThatChapter() async throws {
        let store = try await novel()
        let chapter = try XCTUnwrap(store.manifest.structure.first)
        let note = try await store.addResearchTextNote(parentId: nil, title: "Tides")
        try await store.linkResearch(researchId: note.id, toDocumentId: chapter.id)
        let before = store.manifest.research.count

        fold(for: chapter.id, in: store).actions.newNote(nil)
        _ = await pumpUntil(deadline: 5) { store.manifest.research.count > before }

        let made = try XCTUnwrap(
            TreeWalk.first(in: store.manifest.research,
                           where: { $0.title == "Untitled Note" }))
        let links = TreeWalk.find(id: chapter.id, in: store.manifest.structure)?
            .linkedResearchIds ?? []
        XCTAssertTrue(links.contains(made.id),
                      "a note made from a chapter's fold has to be IN that fold")
    }

    /// The control: a note asked for with a real parent group still lands in
    /// that group, through the tree's own bundle. The re-route is the `nil`
    /// case only — if it had swallowed the parent, every note made inside a
    /// research group from a fold row would have jumped to the piece's root.
    func test_aNoteMadeInsideAFoldsGroupStillLandsInThatGroup() async throws {
        let store = try await collection()
        let piece = try await store.addLoosePiece(title: "Alpha", mode: .prose)
        let group = try await store.addResearchItem(
            parentId: nil, title: "Sources", kind: nil)
        try await store.moveResearchItems(ids: [group.id], to: .piece(piece.id))

        fold(for: piece.id, in: store).actions.newNote(group.id)
        _ = await pumpUntil(deadline: 5) {
            TreeWalk.find(id: group.id, in: store.manifest.research)?
                .children?.isEmpty == false
        }

        let children = TreeWalk.find(id: group.id, in: store.manifest.research)?
            .children ?? []
        XCTAssertEqual(children.map(\.title), ["Untitled Note"])
    }

    // MARK: - Fixtures

    private func novel() async throws -> ProjectStore {
        let url = try await ProjectFactory.createNovelProject(
            named: "Novel-\(UUID().uuidString.prefix(6))", in: temp.url)
        return try await furnish(try await ProjectStore.load(from: url))
    }

    private func shortStory() async throws -> ProjectStore {
        let url = try await ProjectFactory.createShortStoryProject(
            named: "Story-\(UUID().uuidString.prefix(6))", in: temp.url)
        return try await furnish(try await ProjectStore.load(from: url))
    }

    private func screenplay() async throws -> ProjectStore {
        let url = try await ProjectFactory.createScreenplayProject(
            named: "Screenplay-\(UUID().uuidString.prefix(6))", in: temp.url)
        return try await furnish(try await ProjectStore.load(from: url))
    }

    private func collection() async throws -> ProjectStore {
        let url = try await ProjectFactory.createCollectionProject(
            named: "Collection-\(UUID().uuidString.prefix(6))", in: temp.url)
        return try await furnish(try await ProjectStore.load(from: url))
    }

    /// Every fixture opens a `DocumentStore`: the research creators write
    /// through the typed mover and refuse outright without one.
    private func furnish(_ store: ProjectStore) async throws -> ProjectStore {
        let ds = try await DocumentStore.open(url: store.url)
        store.documentStore = ds
        documentStores.append(ds)
        await store.wordCountPopulationTask?.value
        return store
    }

    /// The fold view for a document, as its host mounts it — the same value,
    /// so the bundle these tests ask is the bundle the rows carry.
    private func fold(for documentId: String, in store: ProjectStore) -> BinderPieceFold {
        BinderPieceFold(
            store: store,
            state: BinderTreeSectionsState(),
            selectedSubject: .constant(nil),
            documentId: documentId,
            fold: TreeSectionDerivation.pieceFold(
                forDocumentId: documentId,
                structure: store.manifest.structure,
                research: store.manifest.research,
                projectType: store.manifest.type))
    }

    // MARK: - Hosting and driving

    private func hostBinder(
        store: ProjectStore
    ) async throws -> (NSWindow, BinderSubjectProbe) {
        let probe = BinderSubjectProbe()
        let window = try await mount(AnyView(
            FoldBinderProbeView(store: store, probe: probe)))
        return (window, probe)
    }

    private func hostCollection(
        store: ProjectStore, sweeping: Bool = false
    ) async throws -> (NSWindow, BinderSubjectProbe) {
        let probe = BinderSubjectProbe()
        let window = try await mount(AnyView(
            FoldCollectionProbeView(store: store, probe: probe, sweeping: sweeping)))
        return (window, probe)
    }

    private func hostNavigator(
        store: ProjectStore
    ) async throws -> (NSWindow, BinderSubjectProbe) {
        let probe = BinderSubjectProbe()
        let documentID = TreeWalk.first(
            in: store.manifest.structure, where: { $0.type == .document })?.id
        let window = try await mount(AnyView(FoldNavigatorProbeView(
            store: store, probe: probe, documentID: documentID)))
        return (window, probe)
    }

    private func mount(_ root: AnyView) async throws -> NSWindow {
        let frame = CGRect(x: 0, y: 0, width: 320, height: 800)
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

    /// Unfold a row for real — `NSOutlineView.expandItem`, the same call the
    /// chevron makes — then let SwiftUI's list coordinator produce the rows.
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

    private func select(row: Int, in outline: NSOutlineView,
                        until settled: (() -> Bool)? = nil) async {
        outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        if let settled {
            _ = await pumpUntil(deadline: 5, settled)
        } else {
            await waitOut(0.4)
        }
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
private struct FoldBinderProbeView: View {
    let store: ProjectStore
    let probe: BinderSubjectProbe

    var body: some View {
        BinderView(store: store,
                   selectedSubject: Binding(get: { probe.subject },
                                            set: { probe.subject = $0 }))
    }
}

@MainActor
private struct FoldCollectionProbeView: View {
    let store: ProjectStore
    let probe: BinderSubjectProbe
    /// Attaches the window's own subject sweep (Task 2) — `ProjectWindow` is
    /// where it lives in production, so a pane mounted alone does not carry it.
    let sweeping: Bool
    @State private var renaming: String?

    var body: some View {
        let subject = Binding(get: { probe.subject },
                              set: { probe.subject = $0 })
        CollectionPiecesPane(store: store, selectedSubject: subject,
                             renamingItemId: $renaming)
            .modifier(OptionalSubjectValidation(
                store: sweeping ? store : nil, selectedSubject: subject))
    }
}

@MainActor
private struct FoldNavigatorProbeView: View {
    let store: ProjectStore
    let probe: BinderSubjectProbe
    let documentID: String?

    var body: some View {
        SceneNavigatorPane(
            store: store,
            script: FountainTokenizer().parse("INT. KITCHEN - DAY\n\nLarry sits.\n"),
            projectTitle: store.manifest.title,
            selectedSubject: Binding(get: { probe.subject },
                                     set: { probe.subject = $0 }),
            documentID: documentID,
            onSelect: { _ in })
    }
}

/// `SubjectValidationModifier` when the test asks for it, nothing when it does
/// not — the modifier takes an optional store already, and a `nil` store is
/// exactly how `ProjectWindow` spells "no sweep yet".
@MainActor
private struct OptionalSubjectValidation: ViewModifier {
    let store: ProjectStore?
    @Binding var selectedSubject: BinderSubject?

    func body(content: Content) -> some View {
        content.modifier(SubjectValidationModifier(
            store: store, selectedSubject: $selectedSubject))
    }
}
