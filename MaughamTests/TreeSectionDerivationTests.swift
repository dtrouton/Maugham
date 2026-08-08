import XCTest
import MaughamCore
@testable import Maugham

/// Pure derivation tests for the binder tree's Research/Palette sections and
/// per-piece research fold (shell-finish stage-2a, Task 3). Everything here
/// is built from in-memory manifest values — no disk, no window, no
/// `ProjectStore` — because `TreeSectionDerivation`'s statics take manifest
/// values directly.
final class TreeSectionDerivationTests: XCTestCase {

    // MARK: - Fixtures

    private func group(_ id: String, title: String, path: String? = nil,
                        role: ResearchRole? = nil, children: [ResearchItem] = []) -> ResearchItem {
        ResearchItem(id: id, title: title, type: .group, path: path,
                     children: children.isEmpty ? nil : children, role: role)
    }

    private func asset(_ id: String, title: String, path: String? = nil) -> ResearchItem {
        ResearchItem(id: id, title: title, type: .asset, kind: .document, path: path)
    }

    private func document(_ id: String, title: String, path: String,
                           pieceKind: PieceKind? = nil,
                           linkedResearchIds: [String]? = nil) -> StructureItem {
        StructureItem(id: id, title: title, type: .document, path: path,
                      pieceKind: pieceKind, linkedResearchIds: linkedResearchIds)
    }

    private func group(_ id: String, title: String, children: [StructureItem]) -> StructureItem {
        StructureItem(id: id, title: title, type: .group, children: children)
    }

    // MARK: - sharedResearchRoots: palette group excluded, every project type

    func test_sharedResearchRoots_novel_excludesRoleIdentifiedPaletteGroup() {
        let palette = group("pal", title: "Palette", role: .paletteGroup)
        let shared = asset("res-1", title: "Sarah")
        let roots = TreeSectionDerivation.sharedResearchRoots(
            research: [shared, palette], projectType: .novel)
        XCTAssertEqual(roots.map(\.id), ["res-1"])
    }

    func test_sharedResearchRoots_excludesLegacyPathIdentifiedPaletteGroup() {
        // No role stamped yet — PaletteLookup's path fallback must still catch it.
        let palette = group("pal", title: "Palette", path: "research/palette")
        let shared = asset("res-1", title: "Sarah")
        let roots = TreeSectionDerivation.sharedResearchRoots(
            research: [shared, palette], projectType: .shortStory)
        XCTAssertEqual(roots.map(\.id), ["res-1"])
    }

    func test_sharedResearchRoots_shortStory_noPiecesFilterApplies() {
        // Not a collection — a "pieces/" path is never minted here in practice,
        // but the filter must be a collection-only rule, not path-shaped.
        let odd = asset("res-1", title: "Odd", path: "pieces/x/research/odd.md")
        let roots = TreeSectionDerivation.sharedResearchRoots(
            research: [odd], projectType: .shortStory)
        XCTAssertEqual(roots.map(\.id), ["res-1"])
    }

    func test_sharedResearchRoots_screenplay_noPiecesFilterApplies() {
        let odd = asset("res-1", title: "Odd", path: "pieces/x/research/odd.md")
        let roots = TreeSectionDerivation.sharedResearchRoots(
            research: [odd], projectType: .screenplay)
        XCTAssertEqual(roots.map(\.id), ["res-1"])
    }

    func test_sharedResearchRoots_collection_excludesPieceScopedRootsAndPalette() {
        let palette = group("pal", title: "Palette", role: .paletteGroup)
        let shared = asset("res-shared", title: "Shared Note")
        let pieceRoot = asset(
            "res-piece", title: "Piece Note", path: "pieces/alpha/research/note.md")
        let pieceGroup = group(
            "res-piece-grp", title: "Piece Group", path: "pieces/alpha/research/grp")
        let roots = TreeSectionDerivation.sharedResearchRoots(
            research: [shared, pieceRoot, pieceGroup, palette], projectType: .collection)
        XCTAssertEqual(roots.map(\.id), ["res-shared"])
    }

    func test_sharedResearchRoots_collection_pieceScopedRootAppearsInNoSharedList() {
        let pieceRoot = asset(
            "res-piece", title: "Piece Note", path: "pieces/alpha/research/note.md")
        let roots = TreeSectionDerivation.sharedResearchRoots(
            research: [pieceRoot], projectType: .collection)
        XCTAssertTrue(roots.isEmpty)
    }

    func test_sharedResearchRoots_pathlessItemsAreKeptInACollection() {
        // A pathless link (no `path`) is never piece-scoped by definition —
        // must not be swept out by an unwrapped-optional mistake.
        let link = ResearchItem(id: "res-link", title: "A Link", type: .asset, kind: .link)
        let roots = TreeSectionDerivation.sharedResearchRoots(
            research: [link], projectType: .collection)
        XCTAssertEqual(roots.map(\.id), ["res-link"])
    }

    // MARK: - pieceFold: novel (sharedPlusLink)

    func test_pieceFold_novelChapter_resolvesLinkedItemsInOrder() {
        let sarah = asset("res-sarah", title: "Sarah")
        let mansion = asset("res-mansion", title: "Mansion")
        let chapter = document(
            "ch-1", title: "Chapter 1", path: "manuscript/c1.md",
            linkedResearchIds: ["res-mansion", "res-sarah"])
        let fold = TreeSectionDerivation.pieceFold(
            forDocumentId: "ch-1", structure: [chapter],
            research: [sarah, mansion], projectType: .novel)
        XCTAssertEqual(fold.semantic, .linked)
        XCTAssertEqual(fold.items.map(\.id), ["res-mansion", "res-sarah"])
    }

    func test_pieceFold_novelChapter_skipsOrphanedLinkIds() {
        let sarah = asset("res-sarah", title: "Sarah")
        let chapter = document(
            "ch-1", title: "Chapter 1", path: "manuscript/c1.md",
            linkedResearchIds: ["res-gone", "res-sarah"])
        let fold = TreeSectionDerivation.pieceFold(
            forDocumentId: "ch-1", structure: [chapter],
            research: [sarah], projectType: .novel)
        XCTAssertEqual(fold.semantic, .linked)
        XCTAssertEqual(fold.items.map(\.id), ["res-sarah"])
    }

    func test_pieceFold_novelChapter_noLinksYet_isLinkedButEmpty() {
        let chapter = document("ch-1", title: "Chapter 1", path: "manuscript/c1.md")
        let fold = TreeSectionDerivation.pieceFold(
            forDocumentId: "ch-1", structure: [chapter],
            research: [], projectType: .novel)
        XCTAssertEqual(fold.semantic, .linked)
        XCTAssertTrue(fold.items.isEmpty)
    }

    // MARK: - pieceFold: collection (pieceFolder / sharedOnly for reference)

    func test_pieceFold_collectionLoosePiece_returnsSectionRoots() {
        let piece = document(
            "piece-alpha", title: "Alpha", path: "pieces/alpha/manuscript.md",
            pieceKind: .loose)
        let owned = asset(
            "res-owned", title: "Owned Note", path: "pieces/alpha/research/note.md")
        let other = asset(
            "res-other", title: "Other Piece's Note",
            path: "pieces/beta/research/note.md")
        let fold = TreeSectionDerivation.pieceFold(
            forDocumentId: "piece-alpha", structure: [piece],
            research: [owned, other], projectType: .collection)
        XCTAssertEqual(fold.semantic, .contained)
        XCTAssertEqual(fold.items.map(\.id), ["res-owned"])
    }

    func test_pieceFold_collectionReferencePiece_isNone() {
        let piece = document(
            "piece-ref", title: "Reference", path: "pieces/ref/manuscript.md",
            pieceKind: .reference)
        let fold = TreeSectionDerivation.pieceFold(
            forDocumentId: "piece-ref", structure: [piece],
            research: [], projectType: .collection)
        XCTAssertEqual(fold, .empty)
    }

    // MARK: - pieceFold: single-doc types (sharedOnly)

    func test_pieceFold_shortStory_isNone() {
        let doc = document("doc-1", title: "Story", path: "manuscript/story.md")
        let fold = TreeSectionDerivation.pieceFold(
            forDocumentId: "doc-1", structure: [doc],
            research: [asset("res-1", title: "Note")], projectType: .shortStory)
        XCTAssertEqual(fold, .empty)
    }

    func test_pieceFold_screenplay_isNone() {
        let doc = document("doc-1", title: "Screenplay", path: "manuscript/script.fountain")
        let fold = TreeSectionDerivation.pieceFold(
            forDocumentId: "doc-1", structure: [doc],
            research: [asset("res-1", title: "Note")], projectType: .screenplay)
        XCTAssertEqual(fold, .empty)
    }

    // MARK: - pieceFold: edge cases the routing throws or can't find

    func test_pieceFold_unknownDocId_isNone() {
        let fold = TreeSectionDerivation.pieceFold(
            forDocumentId: "does-not-exist", structure: [], research: [], projectType: .novel)
        XCTAssertEqual(fold, .empty)
    }

    func test_pieceFold_groupIdIsNotADocument_isNone() {
        let child = document("ch-1", title: "Chapter 1", path: "manuscript/c1.md")
        let structureGroup = group("grp-1", title: "Act One", children: [child])
        let fold = TreeSectionDerivation.pieceFold(
            forDocumentId: "grp-1", structure: [structureGroup], research: [], projectType: .novel)
        XCTAssertEqual(fold, .empty)
    }

    func test_pieceFold_unknownProjectType_isNone() {
        let doc = document("doc-1", title: "Doc", path: "manuscript/doc.md")
        let fold = TreeSectionDerivation.pieceFold(
            forDocumentId: "doc-1", structure: [doc], research: [], projectType: .unknown)
        XCTAssertEqual(fold, .empty)
    }
}
