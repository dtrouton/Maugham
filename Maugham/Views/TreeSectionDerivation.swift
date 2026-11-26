import Foundation
import MaughamCore

/// Pure derivations for the binder tree's Research and Palette sections and
/// the per-piece research fold (shell-finish stage-2a, Task 3). Every static
/// here takes manifest values directly — no `ProjectStore`, no disk — so
/// Task 4's mount and this file's own tests can exercise the derivation
/// without a window. The rules themselves are never restated: which research
/// is the book's and which a piece's is `ResearchHomes`, and which documents
/// fold is `ProjectStore.researchRouting(for:projectType:)`.
enum TreeSectionDerivation {

    /// **The tree's Research section: the book's research only** (shell p5
    /// Task 4a) — every item no piece's fold draws, in place, the palette group
    /// out (`PaletteLookup`, role-first). `ResearchHomes.wholeBook`, asked;
    /// a body asks the window's cache instead (`BinderTreeSectionsState.researchHomes`).
    static func sharedResearchRoots(
        structure: [StructureItem], research: [ResearchItem], projectType: ProjectType
    ) -> [ResearchItem] {
        ResearchHomes.derive(structure: structure, research: research,
                             projectType: projectType).wholeBook
    }

    /// A piece's own research, as a fold: the research SOURCE of the tree's
    /// piece fold (`PieceFoldIndex.entries` reads which research a piece holds
    /// from it). What the fold DRAWS —
    /// research, cards, palette, figures, links — is `PieceFoldIndex`'s (shell
    /// p3 Task 7).
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
        /// The roots the piece's own folder holds (a Collection's); the
        /// others it links.
        let owned: Set<String>

        static let empty = PieceFold(items: [], semantic: .none, owned: [])

        /// Whether this research fold has anything in it. The tree's chevron
        /// asks the fold index instead (shell p3 Task 7), whose entries hold
        /// more than research. **Two questions**: a document
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
    /// core — never restates the routing rule. `.pieceFolder` (`.contained`)
    /// and `.sharedPlusLink` (`.linked`) → the piece's `ResearchHomes.foldRoots`,
    /// what its folder holds and what it links; `.sharedOnly` → `.none` (single-doc types have nothing to
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
        return pieceFold(for: item, projectType: projectType,
                         homes: ResearchHomes.derive(structure: structure, research: research,
                                                     projectType: projectType))
    }

    /// The same fold, over an item the caller already has and the homes the
    /// caller derived once for every piece — the binder tree asks this per
    /// piece, and one derivation per piece would be one walk becoming N on the
    /// window's body path.
    ///
    /// **Its rows are `ResearchHomes.foldRoots`** (shell p5 Task 4a): what the
    /// piece's folder holds and what the piece links, each drawn once at the
    /// top of the fold with its group whole beneath it.
    static func pieceFold(
        for item: StructureItem,
        projectType: ProjectType,
        homes: ResearchHomes
    ) -> PieceFold {
        guard let routing = try? ProjectStore.researchRouting(
            for: item, projectType: projectType) else { return .empty }

        let roots = homes.foldRoots(of: item.id)
        let owned = Set(roots.filter { homes.owner(of: $0.id) == item.id }.map(\.id))
        switch routing {
        case .pieceFolder:
            return PieceFold(items: roots, semantic: .contained, owned: owned)
        case .sharedPlusLink:
            return PieceFold(items: roots, semantic: .linked, owned: owned)
        case .sharedOnly:
            return .empty
        }
    }
}
