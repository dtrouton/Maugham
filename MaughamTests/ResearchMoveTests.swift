import XCTest
import MaughamCore
@testable import Maugham

@MainActor
final class ResearchMoveTests: XCTestCase {
    var temp: TempDirectory!

    override func setUp() async throws {
        try await super.setUp()
        temp = try TempDirectory()
    }

    override func tearDown() async throws {
        temp = nil
        try await super.tearDown()
    }

    /// Collection with one loose piece and a wired DocumentStore
    /// (ResearchScopeTests + RenameResearchItemTests patterns combined).
    private func makeCollection() async throws
        -> (URL, ProjectStore, DocumentStore, StructureItem) {
        let url = try await ProjectFactory.createCollectionProject(
            named: "MoveTest", in: temp.url)
        let store = try await ProjectStore.load(from: url)
        let ds = try await DocumentStore.open(url: url)
        store.documentStore = ds
        let piece = try await store.addLoosePiece(title: "Story A", mode: .prose)
        return (url, store, ds, piece)
    }

    private func item(_ store: ProjectStore, _ id: String) -> ResearchItem? {
        TreeWalk.find(id: id, in: store.manifest.research)
    }

    // MARK: shared → piece

    func test_sharedNote_toPiece_movesFileAndRewritesPath() async throws {
        let (url, store, ds, piece) = try await makeCollection()
        let note = try await store.addResearchTextNote(parentId: nil, title: "Sarah")

        try await store.moveResearchItems(ids: [note.id], to: .piece(piece.id))

        let moved = try XCTUnwrap(item(store, note.id))
        let prefix = try XCTUnwrap(ProjectStore.pieceResearchPrefix(for: piece))
        XCTAssertTrue(moved.path!.hasPrefix(prefix), "got \(moved.path!)")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: url.appendingPathComponent(moved.path!).path))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: url.appendingPathComponent("research/sarah.md").path))
        // Now derived as the piece's research
        XCTAssertTrue(store.derivedResearchItems(forDocumentId: piece.id)
            .contains(where: { $0.id == note.id }))
        await ds.close()
    }

    // MARK: piece → shared

    func test_pieceNote_toSharedRoot_movesFileOut() async throws {
        let (url, store, ds, piece) = try await makeCollection()
        let note = try await store.createResearchNote(
            scope: .document(piece.id), title: "Clock Tower")

        try await store.moveResearchItems(ids: [note.id], to: .sharedRoot)

        let moved = try XCTUnwrap(item(store, note.id))
        XCTAssertEqual(moved.path, "research/clock-tower.md")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: url.appendingPathComponent("research/clock-tower.md").path))
        XCTAssertTrue(store.derivedResearchItems(forDocumentId: piece.id).isEmpty)
        await ds.close()
    }

    // MARK: into a group

    func test_move_intoGroup_landsAsChild() async throws {
        let (url, store, ds, _) = try await makeCollection()
        let group = try await store.addResearchItem(
            parentId: nil, title: "World", kind: nil)
        let note = try await store.addResearchTextNote(parentId: nil, title: "Maps")

        try await store.moveResearchItems(ids: [note.id], to: .group(group.id))

        let g = try XCTUnwrap(item(store, group.id))
        XCTAssertTrue((g.children ?? []).contains(where: { $0.id == note.id }))
        let moved = try XCTUnwrap(item(store, note.id))
        XCTAssertEqual(moved.path, "\(g.path!)/maps.md")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: url.appendingPathComponent(moved.path!).path))
        await ds.close()
    }

    // MARK: group with descendants across scope

    func test_group_toPiece_movesFolderAndRewritesDescendants() async throws {
        let (url, store, ds, piece) = try await makeCollection()
        let group = try await store.addResearchItem(
            parentId: nil, title: "Setting", kind: nil)
        let child = try await store.addResearchTextNote(
            parentId: group.id, title: "Harbor")

        try await store.moveResearchItems(ids: [group.id], to: .piece(piece.id))

        let prefix = try XCTUnwrap(ProjectStore.pieceResearchPrefix(for: piece))
        let movedGroup = try XCTUnwrap(item(store, group.id))
        let movedChild = try XCTUnwrap(item(store, child.id))
        XCTAssertTrue(movedGroup.path!.hasPrefix(prefix))
        XCTAssertTrue(movedChild.path!.hasPrefix(movedGroup.path! + "/"))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: url.appendingPathComponent(movedChild.path!).path))
        await ds.close()
    }

    // MARK: link items are manifest-only

    func test_linkItem_moves_manifestOnly() async throws {
        let (url, store, ds, piece) = try await makeCollection()
        let link = try await store.addResearchLink(
            parentId: nil, title: "Ref", url: "https://example.com")

        try await store.moveResearchItems(ids: [link.id], to: .piece(piece.id))

        let moved = try XCTUnwrap(item(store, link.id))
        let prefix = try XCTUnwrap(ProjectStore.pieceResearchPrefix(for: piece))
        XCTAssertTrue(moved.path!.hasPrefix(prefix))
        XCTAssertEqual(moved.url, "https://example.com")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: url.appendingPathComponent(moved.path!).path),
            "synthetic .link path must not create a file")
        await ds.close()
    }

    // MARK: batch + collapsing + validation

    func test_batch_oneBadId_movesNothing() async throws {
        let (url, store, ds, piece) = try await makeCollection()
        let note = try await store.addResearchTextNote(parentId: nil, title: "Keep")

        await XCTAssertThrowsErrorAsync(
            try await store.moveResearchItems(
                ids: [note.id, "res-nope"], to: .piece(piece.id)))

        let kept = try XCTUnwrap(item(store, note.id))
        XCTAssertEqual(kept.path, "research/keep.md")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: url.appendingPathComponent("research/keep.md").path))
        await ds.close()
    }

    func test_selectedDescendant_collapsesIntoSelectedGroup() async throws {
        let (_, store, ds, piece) = try await makeCollection()
        let group = try await store.addResearchItem(
            parentId: nil, title: "Cluster", kind: nil)
        let child = try await store.addResearchTextNote(
            parentId: group.id, title: "Inside")

        // Selecting both must not double-move (RenamePlan would reject the
        // ancestor overlap); the group's move carries the child.
        try await store.moveResearchItems(
            ids: [group.id, child.id], to: .piece(piece.id))

        let movedChild = try XCTUnwrap(item(store, child.id))
        XCTAssertTrue(movedChild.path!.hasPrefix("pieces/"))
        await ds.close()
    }

    func test_groupIntoOwnDescendant_throwsCycle() async throws {
        let (_, store, ds, _) = try await makeCollection()
        let outer = try await store.addResearchItem(parentId: nil, title: "Outer", kind: nil)
        let inner = try await store.addResearchItem(parentId: outer.id, title: "Inner", kind: nil)

        await XCTAssertThrowsErrorAsync(
            try await store.moveResearchItems(ids: [outer.id], to: .group(inner.id))) { error in
            XCTAssertEqual(error as? ProjectStoreError, .cycle)
        }
        await ds.close()
    }

    func test_targetNonGroup_throwsParentNotFound() async throws {
        let (_, store, ds, _) = try await makeCollection()
        let a = try await store.addResearchTextNote(parentId: nil, title: "A")
        let b = try await store.addResearchTextNote(parentId: nil, title: "B")

        await XCTAssertThrowsErrorAsync(
            try await store.moveResearchItems(ids: [a.id], to: .group(b.id)))
        await ds.close()
    }

    // MARK: role guard

    func test_roleItem_crossScope_refuses() async throws {
        let (_, store, ds, piece) = try await makeCollection()
        // Create the palette group via the convention, then stamp its role
        // the way healRole does.
        let group = try await store.addResearchItem(
            parentId: nil, title: PaletteConvention.groupTitle, kind: nil)
        store.mutateResearchItem(id: group.id) { $0.role = .paletteGroup }

        await XCTAssertThrowsErrorAsync(
            try await store.moveResearchItems(ids: [group.id], to: .piece(piece.id)))
        let kept = try XCTUnwrap(item(store, group.id))
        XCTAssertFalse(kept.path!.hasPrefix("pieces/"))
        await ds.close()
    }

    // MARK: role guard — palette-group nesting (final-review C1)

    /// A same-scope `.middle`-drop of the role-stamped palette group onto
    /// another shared group would route through `.group(...)` (scope nil==nil,
    /// so the cross-scope guard passes) and NEST it. But `PaletteLookup`
    /// scans only the TOP level of `research`, so a nested palette group goes
    /// invisible and the next `ensurePaletteGroup` mints a duplicate. The
    /// nesting refusal moves nothing.
    func test_paletteGroup_nestIntoSharedGroup_refusesAndMovesNothing() async throws {
        let (_, store, ds, _) = try await makeCollection()
        let host = try await store.addResearchItem(
            parentId: nil, title: "Shared Group", kind: nil)
        let palette = try await store.addResearchItem(
            parentId: nil, title: PaletteConvention.groupTitle, kind: nil)
        store.mutateResearchItem(id: palette.id) { $0.role = .paletteGroup }

        await XCTAssertThrowsErrorAsync(
            try await store.moveResearchItems(ids: [palette.id], to: .group(host.id)))

        // Moved nothing: palette stays top-level, host gained no child.
        XCTAssertTrue(store.manifest.research.contains { $0.id == palette.id },
            "palette group stays at top level")
        XCTAssertFalse((item(store, host.id)?.children ?? []).contains { $0.id == palette.id })
        // Top-level lookup still resolves it.
        XCTAssertEqual(
            PaletteLookup.paletteGroup(in: store.manifest.research)?.id, palette.id)
        await ds.close()
    }

    /// The nesting refusal must not block a legitimate same-scope TOP-LEVEL
    /// reorder of the palette group (destination is `.sharedRoot`, parentId nil).
    func test_paletteGroup_topLevelReorder_stillWorks() async throws {
        let (_, store, ds, _) = try await makeCollection()
        _ = try await store.addResearchTextNote(parentId: nil, title: "First")
        let palette = try await store.addResearchItem(
            parentId: nil, title: PaletteConvention.groupTitle, kind: nil)
        store.mutateResearchItem(id: palette.id) { $0.role = .paletteGroup }

        try await store.moveResearchItems(ids: [palette.id], to: .sharedRoot, atIndex: 0)

        XCTAssertEqual(store.manifest.research.first?.id, palette.id,
            "palette group reordered to the top of shared research")
        await ds.close()
    }

    // MARK: link cleanup — pathless nested link source scope (final-review C2)

    /// A link minted by `addResearchLink` carries `path: nil`. When it lives
    /// nested inside a group that itself lives under a piece, deriving its
    /// source scope from `item.path` reads nil (→ shared) and the move-out
    /// SKIPS the compensating explicit link. Source scope must be resolved via
    /// the ROOT ancestor (which always carries a reliable path).
    func test_pathlessLinkNestedInPieceGroup_movedToShared_preservesLink() async throws {
        let (_, store, ds, piece) = try await makeCollection()
        let group = try await store.addResearchItem(
            parentId: nil, title: "Cluster", kind: nil)
        try await store.moveResearchItems(ids: [group.id], to: .piece(piece.id))
        // Pathless link minted directly inside the now-piece-scoped group.
        let link = try await store.addResearchLink(
            parentId: group.id, title: "Ref", url: "https://example.com")
        XCTAssertNil(item(store, link.id)?.path, "sanity: nested link path is nil")

        try await store.moveResearchItems(ids: [link.id], to: .sharedRoot)

        XCTAssertTrue(store.linkedResearchIds(forDocumentId: piece.id).contains(link.id),
            "moving a pathless nested link out of the piece must preserve the association")
        await ds.close()
    }

    // MARK: ProjectStoreError renders (final-review I1)

    func test_projectStoreError_localizedDescription_rendersPayload() {
        XCTAssertEqual(
            ProjectStoreError.fileSystemError("boom").localizedDescription, "boom")
        XCTAssertFalse(
            ProjectStoreError.parentNotFound("res-x").localizedDescription
                .contains("ProjectStoreError error"),
            "parentNotFound must render human text, not the Foundation fallback")
    }

    // MARK: single same-parent reorder index (final-review I2)

    /// `ResearchView`'s single-item same-parent drop feeds `moveResearchItem`
    /// a POST-removal index (via `postRemovalInsertionIndex`), matching the
    /// store's remove-then-insert. [A,B,C] drag A below B → [B,A,C], NOT the
    /// pre-removal-index [B,C,A]. Store-level pin of the composed math (the
    /// view logic itself isn't directly testable).
    func test_singleSameParentReorder_dragBelowNext_landsBetween() async throws {
        let (_, store, ds, _) = try await makeCollection()
        let a = try await store.addResearchTextNote(parentId: nil, title: "A")
        let b = try await store.addResearchTextNote(parentId: nil, title: "B")
        let c = try await store.addResearchTextNote(parentId: nil, title: "C")

        let atIndex = ResearchSelectionSync.postRemovalInsertionIndex(
            targetId: b.id, position: .bottom,
            movingIds: [a.id], siblings: store.manifest.research)
        try await store.moveResearchItem(
            id: a.id, toParentId: nil, atIndex: atIndex ?? 0)

        XCTAssertEqual(store.manifest.research.map(\.id), [b.id, a.id, c.id])
        await ds.close()
    }

    // MARK: arrival name collision

    func test_nameCollisionOnArrival_dedupes() async throws {
        let (url, store, ds, piece) = try await makeCollection()
        _ = try await store.createResearchNote(
            scope: .document(piece.id), title: "Sarah")
        let sharedNote = try await store.addResearchTextNote(parentId: nil, title: "Sarah")

        try await store.moveResearchItems(ids: [sharedNote.id], to: .piece(piece.id))

        let moved = try XCTUnwrap(item(store, sharedNote.id))
        XCTAssertTrue(moved.path!.hasSuffix("sarah-2.md"), "got \(moved.path!)")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: url.appendingPathComponent(moved.path!).path))
        await ds.close()
    }

    // MARK: existing single-item mover — _assets orphan regression

    /// Latent bug: the old cross-group branch built a one-step RenamePlan and
    /// left the note's sibling <slug>_assets/ folder behind. Pin the fix.
    func test_crossGroupMove_carriesAssetsFolder() async throws {
        let (url, store, ds, _) = try await makeCollection()
        let group = try await store.addResearchItem(
            parentId: nil, title: "World", kind: nil)
        let note = try await store.addResearchTextNote(parentId: nil, title: "Harbor")
        // Simulate an image note: create the sibling assets folder on disk.
        let assetsURL = url.appendingPathComponent("research/harbor_assets")
        try FileManager.default.createDirectory(
            at: assetsURL, withIntermediateDirectories: true)
        try Data([0xFF]).write(to: assetsURL.appendingPathComponent("img.png"))

        try await store.moveResearchItem(
            id: note.id, toParentId: group.id, atIndex: 0)

        let groupPath = try XCTUnwrap(item(store, group.id)?.path)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: url.appendingPathComponent("\(groupPath)/harbor_assets/img.png").path),
            "assets folder must travel with the note")
        XCTAssertFalse(FileManager.default.fileExists(atPath: assetsURL.path),
            "old assets folder must be gone")
        await ds.close()
    }

    func test_sameParentReorder_stillManifestOnly() async throws {
        let (_, store, ds, _) = try await makeCollection()
        let a = try await store.addResearchTextNote(parentId: nil, title: "A")
        let b = try await store.addResearchTextNote(parentId: nil, title: "B")

        try await store.moveResearchItem(id: b.id, toParentId: nil, atIndex: 0)

        let topIds = store.manifest.research.map(\.id)
        XCTAssertEqual(topIds.firstIndex(of: b.id)! < topIds.firstIndex(of: a.id)!, true)
        XCTAssertEqual(item(store, a.id)?.path, "research/a.md")
        XCTAssertEqual(item(store, b.id)?.path, "research/b.md")
        await ds.close()
    }

    /// Regression (2026-07 multiselect drag): the batch mover removes all
    /// moving items BEFORE inserting at `destIndex`, so a drop index computed
    /// against the pre-removal sibling list drifts. [A,B,C,D,E], drag {A,B}
    /// below D: the view computes the index via
    /// `ResearchSelectionSync.postRemovalInsertionIndex` (post-removal list
    /// [C,D,E] → 2) and the result must be [C,D,A,B,E] — not the pre-fix
    /// [C,D,E,A,B].
    func test_moveBatch_earlierItemsPastLaterTarget_exactOrder() async throws {
        let (_, store, ds, _) = try await makeCollection()
        var ids: [String] = []
        for title in ["A", "B", "C", "D", "E"] {
            ids.append(try await store.addResearchTextNote(
                parentId: nil, title: title).id)
        }
        let (a, b, c, d, e) = (ids[0], ids[1], ids[2], ids[3], ids[4])

        let atIndex = ResearchSelectionSync.postRemovalInsertionIndex(
            targetId: d, position: .bottom,
            movingIds: [a, b], siblings: store.manifest.research)
        try await store.moveResearchItems(
            ids: [a, b], to: .sharedRoot, atIndex: atIndex)

        let order = store.manifest.research.map(\.id).filter { ids.contains($0) }
        XCTAssertEqual(order, [c, d, a, b, e])
        await ds.close()
    }

    // MARK: link cleanup

    func test_moveIntoPiece_dropsNowRedundantExplicitLink() async throws {
        let (_, store, ds, piece) = try await makeCollection()
        let note = try await store.addResearchTextNote(parentId: nil, title: "Sarah")
        try await store.linkResearch(researchId: note.id, toDocumentId: piece.id)

        try await store.moveResearchItems(ids: [note.id], to: .piece(piece.id))

        XCTAssertFalse(store.linkedResearchIds(forDocumentId: piece.id).contains(note.id),
            "containment covers it — explicit link is redundant")
        await ds.close()
    }

    func test_moveOutOfPiece_preservesAssociationAsExplicitLink() async throws {
        let (_, store, ds, piece) = try await makeCollection()
        let note = try await store.createResearchNote(
            scope: .document(piece.id), title: "Clock Tower")

        try await store.moveResearchItems(ids: [note.id], to: .sharedRoot)

        XCTAssertTrue(store.linkedResearchIds(forDocumentId: piece.id).contains(note.id),
            "the piece association must survive the move out")
        await ds.close()
    }

    func test_groupOutOfPiece_linksDescendantAssets() async throws {
        let (_, store, ds, piece) = try await makeCollection()
        let group = try await store.addResearchItem(
            parentId: nil, title: "Cluster", kind: nil)
        let child = try await store.addResearchTextNote(parentId: group.id, title: "Inside")
        try await store.moveResearchItems(ids: [group.id], to: .piece(piece.id))

        try await store.moveResearchItems(ids: [group.id], to: .sharedRoot)

        let links = store.linkedResearchIds(forDocumentId: piece.id)
        XCTAssertTrue(links.contains(child.id), "descendant assets get the link")
        XCTAssertFalse(links.contains(group.id), "groups themselves are not linked")
        await ds.close()
    }

    func test_pieceToPiece_movesLinkCleanupBothEnds() async throws {
        let (_, store, ds, pieceA) = try await makeCollection()
        let pieceB = try await store.addLoosePiece(title: "Story B", mode: .prose)
        let note = try await store.createResearchNote(
            scope: .document(pieceA.id), title: "Shared Cast")
        try await store.linkResearch(researchId: note.id, toDocumentId: pieceB.id)

        try await store.moveResearchItems(ids: [note.id], to: .piece(pieceB.id))

        XCTAssertFalse(store.linkedResearchIds(forDocumentId: pieceB.id).contains(note.id),
            "arrived into B's containment — link redundant")
        XCTAssertFalse(store.linkedResearchIds(forDocumentId: pieceA.id).contains(note.id),
            "piece→piece transfers the association; A gets no link")
        await ds.close()
    }

    // MARK: batch delete

    func test_deleteResearchItems_batchOneSave() async throws {
        let (url, store, ds, _) = try await makeCollection()
        let a = try await store.addResearchTextNote(parentId: nil, title: "A")
        let b = try await store.addResearchTextNote(parentId: nil, title: "B")
        let link = try await store.addResearchLink(
            parentId: nil, title: "L", url: "https://x.example")

        try await store.deleteResearchItems(ids: [a.id, b.id, link.id])

        XCTAssertNil(item(store, a.id))
        XCTAssertNil(item(store, b.id))
        XCTAssertNil(item(store, link.id))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: url.appendingPathComponent("research/a.md").path))
        XCTAssertNotNil(store.lastDeletedTrashId)
        await ds.close()
    }

    func test_deleteResearchItems_descendantCollapses() async throws {
        let (_, store, ds, _) = try await makeCollection()
        let group = try await store.addResearchItem(parentId: nil, title: "G", kind: nil)
        let child = try await store.addResearchTextNote(parentId: group.id, title: "C")

        // Selecting both must not attempt to trash the child twice.
        try await store.deleteResearchItems(ids: [group.id, child.id])

        XCTAssertNil(item(store, group.id))
        XCTAssertNil(item(store, child.id))
        await ds.close()
    }

    /// Never-moved link: `addResearchLink` mints `path: nil`. Confirms the
    /// path-less branch still works after the refactor.
    func test_deleteResearchItems_neverMovedLink_pathLessDelete() async throws {
        let (_, store, ds, _) = try await makeCollection()
        let link = try await store.addResearchLink(
            parentId: nil, title: "Ref", url: "https://example.com")
        XCTAssertNil(item(store, link.id)?.path, "sanity: never-moved link has no path")

        try await store.deleteResearchItems(ids: [link.id])

        XCTAssertNil(item(store, link.id))
        await ds.close()
    }

    /// Moved link: after `moveResearchItems` a link carries a synthetic
    /// `.link` path with no file backing it (ADR-noted in moveResearchItem).
    /// Deleting it must NOT attempt to trash that path (no file exists there)
    /// — it must fall through to manifest-only removal like the path-less
    /// case, matching the fidelity-check finding that the old, unguarded
    /// `if let path = item.path, !path.isEmpty` branch would otherwise call
    /// into `trash(relativePath:)` against a nonexistent file and throw.
    func test_deleteResearchItems_movedLink_syntheticPathDelete() async throws {
        let (_, store, ds, piece) = try await makeCollection()
        let link = try await store.addResearchLink(
            parentId: nil, title: "Ref", url: "https://example.com")
        try await store.moveResearchItems(ids: [link.id], to: .piece(piece.id))
        let moved = try XCTUnwrap(item(store, link.id))
        XCTAssertNotNil(moved.path, "sanity: moved link now carries a synthetic path")

        try await store.deleteResearchItems(ids: [link.id])

        XCTAssertNil(item(store, link.id))
        await ds.close()
    }

    // MARK: section classification (sectionScope core: researchRootPath + scope)
    //
    // `CollectionResearchPane.sectionScope(ofItemId:)` — the load-bearing
    // classifier that decides same-section reorder vs cross-section scope move —
    // is `ProjectStore.researchRootPath(ofItemId:in:)` mapped through
    // `researchScopePieceId(ofPath:)`. These pin that composed logic for the
    // three cases that broke naive path-on-the-item classification.

    func test_sectionScope_nestedInSharedGroup_resolvesShared() async throws {
        let (_, store, ds, _) = try await makeCollection()
        let group = try await store.addResearchItem(
            parentId: nil, title: "Notes", kind: nil)
        let child = try await store.addResearchTextNote(
            parentId: group.id, title: "Inside")

        let rootPath = ProjectStore.researchRootPath(
            ofItemId: child.id, in: store.manifest.research)
        XCTAssertEqual(rootPath, item(store, group.id)?.path)
        XCTAssertNil(store.researchScopePieceId(ofPath: rootPath),
                     "shared group → shared section")
        await ds.close()
    }

    func test_sectionScope_nestedInPieceGroup_resolvesPiece() async throws {
        let (_, store, ds, piece) = try await makeCollection()
        let group = try await store.addResearchItem(
            parentId: nil, title: "Notes", kind: nil)
        let child = try await store.addResearchTextNote(
            parentId: group.id, title: "Inside")
        // Relocate the whole group into the piece's research folder.
        try await store.moveResearchItems(ids: [group.id], to: .piece(piece.id))

        let rootPath = ProjectStore.researchRootPath(
            ofItemId: child.id, in: store.manifest.research)
        XCTAssertEqual(rootPath, item(store, group.id)?.path)
        XCTAssertEqual(store.researchScopePieceId(ofPath: rootPath), piece.id,
                       "group moved under the piece → piece section")
        await ds.close()
    }

    func test_sectionScope_pathlessLinkInSharedGroup_resolvesViaRoot() async throws {
        let (_, store, ds, _) = try await makeCollection()
        let group = try await store.addResearchItem(
            parentId: nil, title: "Notes", kind: nil)
        // A never-moved link mints `path: nil` — classifying by its own path
        // would misread it as shared by accident; classifying by root is what
        // makes it correct.
        let link = try await store.addResearchLink(
            parentId: group.id, title: "Ref", url: "https://example.com")
        XCTAssertNil(item(store, link.id)?.path, "sanity: link path is nil")

        let rootPath = ProjectStore.researchRootPath(
            ofItemId: link.id, in: store.manifest.research)
        XCTAssertEqual(rootPath, item(store, group.id)?.path)
        XCTAssertNil(store.researchScopePieceId(ofPath: rootPath),
                     "pathless link inside a shared group → shared section")
        await ds.close()
    }

    // MARK: - cross-section single-item move index (Task 9 side-fix)

    /// A cross-section single-item row-drop must compute its landing slot
    /// POST-removal. `manifest.research` is one flat array holding BOTH
    /// sections' top-level items; when the moved (piece) item precedes the
    /// (shared) target in that array, a pre-removal index drifts right by one
    /// and the item lands after the target instead of before it. Pins the
    /// `postRemovalInsertionIndex`-derived landing the view now uses.
    func test_crossSectionMove_moverPrecedesTarget_landsBeforeTarget() async throws {
        let (_, store, ds, piece) = try await makeCollection()
        // Flat order [P, S0, S1]: piece note first, then two shared notes.
        let p = try await store.createResearchNote(
            scope: .document(piece.id), title: "P")
        let s0 = try await store.addResearchTextNote(parentId: nil, title: "S0")
        let s1 = try await store.addResearchTextNote(parentId: nil, title: "S1")

        let order = store.manifest.research.map(\.id)
        let pIdx = try XCTUnwrap(order.firstIndex(of: p.id))
        let s1Idx = try XCTUnwrap(order.firstIndex(of: s1.id))
        XCTAssertLessThan(pIdx, s1Idx, "precondition: mover precedes target")

        // Drop P above S1. The correct post-removal index is 1 (filtered
        // siblings [S0,S1]); the naive pre-removal index would be s1Idx (2).
        let atIndex = ResearchSelectionSync.postRemovalInsertionIndex(
            targetId: s1.id, position: .top,
            movingIds: [p.id], siblings: store.manifest.research)
        XCTAssertEqual(atIndex, 1, "post-removal index, not pre-removal \(s1Idx)")

        try await store.moveResearchItems(
            ids: [p.id], to: .sharedRoot, atIndex: atIndex)

        XCTAssertEqual(store.manifest.research.map(\.id), [s0.id, p.id, s1.id],
                       "P lands before S1, not after it")
        await ds.close()
    }
}

func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    _ message: String = "", file: StaticString = #filePath, line: UInt = #line,
    _ errorHandler: (Error) -> Void = { _ in }
) async {
    do {
        _ = try await expression()
        XCTFail("Expected error. \(message)", file: file, line: line)
    } catch {
        errorHandler(error)
    }
}
