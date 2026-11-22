import Foundation
import MaughamCore

/// **What Brief is about**, answered once from the faces' subject (shell
/// plan 3). A value: `BriefReader` reads by it and nothing else.
///
/// **Its own type, not `ResolveScope`.** To resolve folds the Book and a Part
/// into one `.pieces` case (both are "the items under these documents") and
/// has a `.figure` case; Brief must tell the Book from a Part (the Book has an
/// intent and gathers every origin, a Part has neither), has nothing for a
/// figure, and has an edition's brief. The screenplay rule is not restated:
/// `of` asks `ResolveScope.of` and takes its answer.
enum BriefScope: Hashable {
    /// One manuscript document — also a screenplay's Book (its one script).
    case piece(docId: String)
    /// A group: its non-reference document descendants, in manuscript order.
    /// A Part has no intent of its own; its Brief gathers its pieces' decisions.
    case part(groupId: String, docIds: [String])
    /// The project.
    case book
    /// An edition: its edition brief.
    case edition(language: String)
    /// A Collection piece with `pieceKind == .reference`: it belongs to
    /// another project, so its Brief is there.
    case elsewhere(docId: String)
    /// The Inbox, the Canvas, the Palette, a figure, research: nothing here
    /// is held to an intent.
    case outside

    /// The scope of `faces`, deferring to `ResolveScope.of` for what a
    /// document, a reference piece, a group and a screenplay's Book are.
    static func of(_ faces: BinderSubject, structure: [StructureItem],
                   projectType: ProjectType) -> BriefScope {
        switch faces {
        case .project:
            // ADR 0036 decision 3's rule, applied as To resolve applies it.
            // The faces are the Book here, never an edition: no source
            // language is asked.
            if case .piece(let docId, _) = ResolveScope.of(faces, readIn: nil,
                                                          sourceLanguage: PublishConfig.Metadata().language,
                                                          structure: structure,
                                                          projectType: projectType) {
                return .piece(docId: docId)
            }
            return .book
        case .item(let id):
            switch ResolveScope.of(faces, readIn: nil,
                                   sourceLanguage: PublishConfig.Metadata().language,
                                   structure: structure, projectType: projectType) {
            // A piece's Brief is the piece's, whatever it is read in.
            case .piece(let docId, _), .pieceInLanguage(let docId, _): return .piece(docId: docId)
            case .elsewhere(let docId): return .elsewhere(docId: docId)
            case .pieces(let docIds, _): return .part(groupId: id, docIds: docIds)
            case .figure, .edition, .outside: return .outside
            }
        case .edition(let language):
            return .edition(language: language)
        case .research, .figure, .inbox, .canvas, .palette:
            return .outside
        }
    }
}
