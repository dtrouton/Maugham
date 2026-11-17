import Foundation
import MaughamCore

/// **What To resolve is about**, answered once from the faces' subject
/// (shell plan 2). A value: the reader filters by it and nothing else.
enum ResolveScope: Hashable {
    /// One manuscript document. `includesBookLevel` is true for a
    /// screenplay's Book only: grouped as its one script, it still holds the
    /// Book's own to-dos.
    case piece(docId: String, includesBookLevel: Bool = false)
    /// The Book (`includesBookLevel: true` — the Book's own to-dos and every
    /// figure's notes come too) or a Part (false), its documents in
    /// manuscript order. Reference pieces are never among them.
    case pieces(docIds: [String], includesBookLevel: Bool)
    /// One figure's notes.
    case figure(id: String)
    /// A Collection piece with `pieceKind == .reference`: it belongs to
    /// another project, so it holds nothing here.
    case elsewhere(docId: String)
    /// An edition, the Canvas, the Inbox, the Palette, a research item —
    /// nothing To resolve gathers is about these.
    case outside

    /// The scope of `faces`. `.item` naming a document is `.piece` (a
    /// reference piece `.elsewhere`), a group `.pieces` over its document
    /// descendants, `.project` `.pieces(includesBookLevel: true)` over every
    /// document — except a screenplay's Book, which is `.piece` over its one
    /// script, still holding the Book's own to-dos. An id the structure does not hold is `.outside`.
    static func of(_ faces: BinderSubject, structure: [StructureItem],
                   projectType: ProjectType) -> ResolveScope {
        switch faces {
        case .project:
            let docs = documents(in: structure)
            if isOneScript(projectType), docs.count == 1 {
                return .piece(docId: docs[0], includesBookLevel: true)
            }
            return .pieces(docIds: docs, includesBookLevel: true)
        case .item(let id):
            guard let item = TreeWalk.find(id: id, in: structure) else { return .outside }
            switch item.type {
            case .document:
                return isReference(item) ? .elsewhere(docId: id) : .piece(docId: id)
            case .group:
                return .pieces(docIds: documents(in: item.children ?? []), includesBookLevel: false)
            }
        case .figure(let id):
            return .figure(id: id)
        case .research, .inbox, .canvas, .palette, .edition:
            return .outside
        }
    }

    /// The documents whose items the scope holds, in manuscript order. A
    /// figure scope names the figure's stream; `.elsewhere` and `.outside`
    /// name none.
    var docIds: [String] {
        switch self {
        case .piece(let docId, _): return [docId]
        case .pieces(let docIds, _): return docIds
        case .figure(let id): return [id]
        case .elsewhere, .outside: return []
        }
    }

    /// The Book's own level — its to-dos and the notes on figures no piece owns.
    var includesBookLevel: Bool {
        switch self {
        case .piece(_, let book), .pieces(_, let book): return book
        case .figure, .elsewhere, .outside: return false
        }
    }

    // MARK: - Helpers

    /// Every non-reference document under `items`, pre-order.
    private static func documents(in items: [StructureItem]) -> [String] {
        TreeWalk.collect(in: items) { $0.type == .document && !isReference($0) }.map(\.id)
    }

    private static func isReference(_ item: StructureItem) -> Bool {
        item.pieceKind == .reference
    }

    /// A screenplay is one script (single-file screenplays, CLAUDE.md).
    /// Exhaustive on purpose (tripwire 55): a new kind decides.
    private static func isOneScript(_ type: ProjectType) -> Bool {
        switch type {
        case .screenplay: return true
        case .shortStory, .novel, .collection, .unknown: return false
        }
    }
}
