import Foundation
import MaughamCore

/// Craft-intent doc seam. One optional freeform markdown doc per intent scope:
/// the project (novel/screenplay/short-story/collection), or a loose collection
/// piece. Plain-edited research-note content — op-log-free. ABSENCE IS VALID:
/// lookups return nil without side effects; nothing nags. A collection
/// *reference* piece's intent belongs to its own project (project scope there).
extension ProjectStore {

    public static let craftIntentFileName = PaletteConvention.craftIntentFileName
    public static let craftIntentTitle = PaletteConvention.craftIntentTitle

    /// Locate the intent doc for a scope. nil pieceId = project scope.
    /// Unknown pieceIds return nil (nothing exists for them by definition).
    /// Role-first (survives renaming the note away from `craft-intent.md`);
    /// falls back to the legacy filename. A fallback hit lazily heals the
    /// manifest — see `stampRole`.
    public func craftIntentItem(forPieceId pieceId: String?) -> ResearchItem? {
        guard let prefix = craftIntentResearchPrefix(forPieceId: pieceId) else { return nil }
        guard let item = PaletteLookup.craftIntentItem(
            in: manifest.research, researchPrefix: prefix) else { return nil }
        healRole(of: item, to: .craftIntent)
        return item
    }

    /// Find-or-create the intent doc for a scope (idempotent). Stamps
    /// `role = .craftIntent` on create, and heals a legacy path-identified
    /// note on find. Throws for pieceIds that are not valid research targets
    /// (unknown ids, groups, reference pieces) — never silently falls back to
    /// project scope.
    @discardableResult
    public func createCraftIntent(forPieceId pieceId: String?) async throws -> ResearchItem {
        if let existing = craftIntentItem(forPieceId: pieceId) {
            if existing.role != .craftIntent {
                try await stampRole(itemId: existing.id, role: .craftIntent)
                return findResearchItem(id: existing.id, in: manifest.research) ?? existing
            }
            return existing
        }
        let created: ResearchItem
        if let pieceId {
            created = try await createResearchNote(
                scope: .document(pieceId), title: Self.craftIntentTitle)
        } else {
            created = try await addResearchTextNote(parentId: nil, title: Self.craftIntentTitle)
        }
        try await stampRole(itemId: created.id, role: .craftIntent)
        return findResearchItem(id: created.id, in: manifest.research) ?? created
    }

    /// The project-relative research directory prefix the scope's intent doc
    /// lives under, or nil when the scope has no intent home (unknown piece,
    /// reference piece). "research" = project scope; a loose piece scopes to
    /// its own `.../research/` subtree.
    private func craftIntentResearchPrefix(forPieceId pieceId: String?) -> String? {
        guard let pieceId else { return "research" }
        guard let piece = TreeWalk.collect(
                  in: manifest.structure, where: { $0.id == pieceId }).first,
              let prefix = Self.pieceResearchPrefix(for: piece) else { return nil }
        return prefix
    }
}
