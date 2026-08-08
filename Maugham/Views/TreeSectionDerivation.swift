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
    /// `ResearchView.swift:19` still renders the group inline and is
    /// untouched here) — and, for collections, every root under a loose
    /// piece's `pieces/…/research/` prefix
    /// (`CollectionResearchPane.sharedItems()`'s rule, hoisted so the
    /// collection pane and the tree agree on the same shape; both call
    /// through here in Task 4, they don't re-derive it).
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
        guard let item = TreeWalk.find(id: docId, in: structure),
              let routing = try? ProjectStore.researchRouting(for: item, projectType: projectType)
        else { return .empty }

        switch routing {
        case .pieceFolder(let pieceId):
            let items = ProjectStore.pieceResearchSectionRoots(
                forDocumentId: pieceId, structure: structure,
                research: research, projectType: projectType)
            return PieceFold(items: items, semantic: .contained)
        case .sharedPlusLink(let documentId):
            let ids = ProjectStore.findItemLinks(documentId: documentId, in: structure) ?? []
            let items = ids.compactMap { TreeWalk.find(id: $0, in: research) }
            return PieceFold(items: items, semantic: .linked)
        case .sharedOnly:
            return .empty
        }
    }
}
