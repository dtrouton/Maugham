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
    public func craftIntentItem(forPieceId pieceId: String?) -> ResearchItem? {
        guard let expectedPath = craftIntentPath(forPieceId: pieceId) else { return nil }
        return TreeWalk.collect(in: manifest.research, where: { item in
            item.type == .asset && item.path == expectedPath
        }).first
    }

    /// Find-or-create the intent doc for a scope (idempotent). Throws for
    /// pieceIds that are not valid research targets (unknown ids, groups,
    /// reference pieces) — never silently falls back to project scope.
    @discardableResult
    public func createCraftIntent(forPieceId pieceId: String?) async throws -> ResearchItem {
        if let existing = craftIntentItem(forPieceId: pieceId) { return existing }
        if let pieceId {
            return try await createResearchNote(
                scope: .document(pieceId), title: Self.craftIntentTitle)
        }
        return try await addResearchTextNote(parentId: nil, title: Self.craftIntentTitle)
    }

    /// The project-relative path the scope's intent doc lives at, or nil when
    /// the scope has no intent home (unknown piece, reference piece).
    private func craftIntentPath(forPieceId pieceId: String?) -> String? {
        guard let pieceId else { return "research/" + Self.craftIntentFileName }
        guard let piece = TreeWalk.collect(
                  in: manifest.structure, where: { $0.id == pieceId }).first,
              let prefix = Self.pieceResearchPrefix(for: piece) else { return nil }
        return prefix + Self.craftIntentFileName
    }
}
