import Foundation
import MaughamCore

/// Where a new research item lands (typed cross-area seam, ADR 0010 pattern).
/// `.document` routes by project type — collection loose piece → the piece's
/// research/ folder (containment: travels on promotion, ADR-free portability);
/// novel chapter → shared research + `linkedResearchIds`; single-doc types →
/// shared research (derivation already surfaces everything as the document's).
/// Spec: docs/superpowers/specs/2026-07-07-scoped-research-design.md
public enum ResearchScope: Equatable {
    case shared
    case document(String)
}

extension ProjectStore {

    /// How `.document(id)` routes for this project. Throws on ids that are
    /// not valid targets (unknown, groups, collection reference pieces) —
    /// never falls back to `.shared` silently.
    enum ResearchRouting: Equatable {
        case pieceFolder(pieceId: String)
        case sharedPlusLink(documentId: String)
        case sharedOnly
    }

    func researchRouting(forDocumentId docId: String) throws -> ResearchRouting {
        guard let item = TreeWalk.collect(
            in: manifest.structure, where: { $0.id == docId }).first else {
            throw ProjectStoreError.fileSystemError(
                "Unknown research target document: \(docId)")
        }
        guard item.type == .document else {
            throw ProjectStoreError.fileSystemError(
                "Research target must be a document, not a group: \(docId)")
        }
        switch manifest.type {
        case .collection:
            guard item.pieceKind == .loose else {
                throw ProjectStoreError.fileSystemError(
                    "Referenced pieces keep research in their own project: \(docId)")
            }
            return .pieceFolder(pieceId: docId)
        case .novel:
            return .sharedPlusLink(documentId: docId)
        case .shortStory, .screenplay:
            return .sharedOnly
        case .unknown:
            throw ProjectStoreError.fileSystemError(
                "Cannot scope research in a project of unknown type")
        }
    }

    /// True when `docId` is a valid `.document` research-scope target.
    public func isResearchScopeTarget(_ docId: String) -> Bool {
        (try? researchRouting(forDocumentId: docId)) != nil
    }

    /// All valid `.document` scope targets (drives the promote-target picker).
    public func researchScopeTargets() -> [StructureItem] {
        TreeWalk.collect(in: manifest.structure, where: { $0.type == .document })
            .filter { isResearchScopeTarget($0.id) }
    }

    // MARK: - Scoped creation

    private func route(
        _ scope: ResearchScope,
        shared: () async throws -> ResearchItem,
        piece: (String) async throws -> ResearchItem
    ) async throws -> ResearchItem {
        switch scope {
        case .shared:
            return try await shared()
        case .document(let docId):
            switch try researchRouting(forDocumentId: docId) {
            case .pieceFolder(let pieceId):
                return try await piece(pieceId)
            case .sharedPlusLink(let documentId):
                let item = try await shared()
                try await linkResearch(researchId: item.id, toDocumentId: documentId)
                return item
            case .sharedOnly:
                return try await shared()
            }
        }
    }

    @discardableResult
    public func createResearchNote(
        scope: ResearchScope, title: String = "Untitled Note"
    ) async throws -> ResearchItem {
        try await route(scope,
            shared: { try await addResearchTextNote(parentId: nil, title: title) },
            piece: { try await addPieceResearchNote(pieceId: $0, title: title) })
    }

    @discardableResult
    public func createResearchAsset(
        scope: ResearchScope, fromURL sourceURL: URL
    ) async throws -> ResearchItem {
        try await route(scope,
            shared: { try await addResearchAsset(parentId: nil, fromURL: sourceURL) },
            piece: { try await addPieceResearchAsset(pieceId: $0, fromURL: sourceURL) })
    }

    @discardableResult
    public func createResearchLink(
        scope: ResearchScope, title: String, url linkURL: String
    ) async throws -> ResearchItem {
        try await route(scope,
            shared: { try await addResearchLink(parentId: nil, title: title, url: linkURL) },
            piece: { try await addPieceResearchLink(pieceId: $0, title: title, url: linkURL) })
    }

    // MARK: - Derived (structural) association

    /// Path prefix under which a collection loose piece's research lives, or
    /// nil for anything else. THE containment predicate — CollectionResearchPane
    /// and derivedResearchItems must both use this (spec: derivation agreement).
    public static func pieceResearchPrefix(for piece: StructureItem) -> String? {
        guard piece.pieceKind == .loose, let piecePath = piece.path else { return nil }
        return "\((piecePath as NSString).deletingLastPathComponent)/research/"
    }

    /// Research items structurally associated with a document — no link record.
    /// Collection loose piece → containment (path prefix); single-doc project
    /// types → every research asset; multi-doc (novel) → none (chapters
    /// associate via linkedResearchIds only).
    public func derivedResearchItems(forDocumentId docId: String) -> [ResearchItem] {
        switch manifest.type {
        case .collection:
            guard let piece = manifest.structure.first(where: { $0.id == docId }),
                  let prefix = Self.pieceResearchPrefix(for: piece) else { return [] }
            return manifest.research.filter { $0.path?.hasPrefix(prefix) == true }
        case .shortStory, .screenplay:
            return TreeWalk.collect(in: manifest.research, where: { $0.type == .asset })
        case .novel, .unknown:
            return []
        }
    }

    /// Items the link picker offers: everything except what is already
    /// structurally associated (linking those would be redundant).
    public func linkableResearchItems(forDocumentId docId: String) -> [ResearchItem] {
        let derivedIds = Set(derivedResearchItems(forDocumentId: docId).map(\.id))
        return TreeWalk.collect(in: manifest.research, where: { _ in true })
            .filter { !derivedIds.contains($0.id) }
    }
}
