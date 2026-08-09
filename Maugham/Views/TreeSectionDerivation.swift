import Foundation
import MaughamCore

/// Pure derivations for the binder tree's Research and Palette sections and
/// the per-piece research fold (shell-finish stage-2a, Task 3). Every static
/// here takes manifest values directly — no `ProjectStore`, no disk — so
/// Task 4's mount and this file's own tests can exercise the derivation
/// without a window. The routing rules themselves are never restated: this
/// file calls the pure cores `ResearchScope.swift` extracted for it
/// (`ProjectStore.researchRouting(for:projectType:)`,
/// `ProjectStore.pieceResearchSectionRoots(forDocumentId:structure:research:projectType:)`).
enum TreeSectionDerivation {

    /// Top-level research roots for the tree's Research section: every
    /// manifest root EXCEPT the palette group — found role-first via
    /// `PaletteLookup` (falls back to the legacy `research/palette` path, so
    /// an un-healed project's group is still excluded; this is the
    /// first-ever palette filter on a research surface, since
    /// the deleted `ResearchView` rendered the group inline and was
    /// untouched here) — and, for collections, every root under a loose
    /// piece's `pieces/…/research/` prefix
    /// (the deleted `CollectionResearchPane.sharedItems()`'s rule, hoisted in
    /// stage-2a Task 4 so the pane and the tree agreed on one shape rather
    /// than re-deriving it; the pane went in stage 2b Task 7 and the rule
    /// stayed).
    static func sharedResearchRoots(
        research: [ResearchItem], projectType: ProjectType
    ) -> [ResearchItem] {
        let paletteGroupId = PaletteLookup.paletteGroup(in: research)?.id
        return research.filter { item in
            guard item.id != paletteGroupId else { return false }
            guard projectType == .collection, let path = item.path else { return true }
            return !path.hasPrefix("pieces/")
        }
    }

    /// The per-piece research fold shown under a manuscript document's row.
    struct PieceFold: Equatable {
        /// What kind of fold this is, independent of whether it happens to be
        /// empty right now — an empty `.contained`/`.linked` fold is still a
        /// valid fold with nothing in it yet (Task 4/6 render those
        /// differently from a document that can't fold at all).
        enum Semantic: Equatable {
            case contained
            case linked
            case none
        }

        let items: [ResearchItem]
        let semantic: Semantic

        static let empty = PieceFold(items: [], semantic: .none)

        /// Whether the tree draws this piece's row as a `DisclosureGroup`
        /// (Task 6). **Two questions, and the tree asks both**: a document
        /// that cannot fold at all (`.none`) and one that folds onto nothing
        /// yet are different facts about the manifest, but they are the same
        /// row on screen — a chevron opening onto nothing is noise, and on a
        /// novel whose writer has linked no research it would be noise on
        /// every chapter. The empty fold is not a dead end: the piece row
        /// stays a drop target (Task 7), which is the affordance for the
        /// first item.
        var showsDisclosure: Bool { semantic != .none && !items.isEmpty }
    }

    /// Derives a document's fold from `ProjectStore.researchRouting`'s pure
    /// core — never restates the routing rule. `.pieceFolder` → the piece's
    /// own research subtree roots (`.contained`); `.sharedPlusLink` → the
    /// document's linked shared items, resolved and order-preserved
    /// (`.linked`); `.sharedOnly` → `.none` (single-doc types have nothing to
    /// fold — everything is already the document's, spec's derivation).
    /// A missing document, a group id, a collection reference piece, or an
    /// unknown project type all fail `researchRouting` and land on `.none`
    /// too: the tree fold is presentation, not validation —
    /// `researchScopeTargets()` stays the source of truth for what's a valid
    /// link/promote target.
    static func pieceFold(
        forDocumentId docId: String,
        structure: [StructureItem],
        research: [ResearchItem],
        projectType: ProjectType
    ) -> PieceFold {
        guard let item = TreeWalk.find(id: docId, in: structure) else { return .empty }
        return pieceFold(for: item, structure: structure,
                         research: research, projectType: projectType)
    }

    /// The same fold, over an item the caller already has.
    ///
    /// **The binder tree draws one row per structure item and asks for that
    /// item's fold**, so the by-id spelling above would walk the whole
    /// structure to find the very item the row was handed — one walk becoming
    /// N, on the window's body path. `ProjectStore.researchRouting` was split
    /// for exactly this reason and records the same measurement; this is that
    /// split carried one level up, so the tree's per-row cost is the fold's
    /// own work and not a search for its subject.
    static func pieceFold(
        for item: StructureItem,
        structure: [StructureItem],
        research: [ResearchItem],
        projectType: ProjectType
    ) -> PieceFold {
        guard let routing = try? ProjectStore.researchRouting(
            for: item, projectType: projectType) else { return .empty }

        switch routing {
        case .pieceFolder(let pieceId):
            let items = ProjectStore.pieceResearchSectionRoots(
                forDocumentId: pieceId, structure: structure,
                research: research, projectType: projectType)
            return PieceFold(items: items, semantic: .contained)
        case .sharedPlusLink:
            // The document's own `linkedResearchIds`, read off the item rather
            // than through `ProjectStore.findItemLinks(documentId:in:)` — that
            // helper is `TreeWalk.find(id:).linkedResearchIds`, so asking it
            // here would walk the whole structure again to arrive back at the
            // item this function was handed. Same list, one walk fewer per row.
            let items = (item.linkedResearchIds ?? [])
                .compactMap { TreeWalk.find(id: $0, in: research) }
            return PieceFold(items: items, semantic: .linked)
        case .sharedOnly:
            return .empty
        }
    }
}
