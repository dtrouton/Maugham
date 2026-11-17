import Foundation
import MaughamCore

/// **One thing raised about the faces' subject** — what To resolve lists
/// (shell plan 2). Three kinds, read without loading a document
/// (`ResolveReader`):
///
/// - a note: an OPEN `Annotation` from the project walk, whoever wrote it — a
///   check's continuity questions, reader reports and letter questions are
///   notes too (they carry a `compilerRunId`) and are listed once, here;
/// - a finding: a check's conformance strain from the diagnostics sidecar,
///   the one kind that is **replaced by the next check**;
/// - a to-do: an OPEN `WriterTask`.
enum ResolveItem: Identifiable, Equatable {
    case note(ProjectAnnotation)
    case finding(docId: String, Diagnostic)
    case todo(WriterTask)

    /// Kind-prefixed and document-qualified, so a note, a finding and a to-do
    /// never collide, nor two kinds' ids minted in two documents.
    var id: String {
        switch self {
        case .note(let note): return "note:\(note.docId)/\(note.annotation.id)"
        case .finding(let docId, let finding): return "finding:\(docId)/\(finding.id)"
        case .todo(let task): return "todo:\(docId)/\(task.id)"
        }
    }

    /// The document the item belongs to. A to-do with no anchor is the
    /// Book's: `ProjectStore.projectTasksDocId`.
    var docId: String {
        switch self {
        case .note(let note): return note.docId
        case .finding(let docId, _): return docId
        case .todo(let task): return task.anchor?.docId ?? ProjectStore.projectTasksDocId
        }
    }

    /// The paragraph the item points at, when it points at one.
    var paragraphId: String? {
        switch self {
        case .note(let note): return note.annotation.paragraphId
        case .finding(_, let finding): return finding.anchor?.paragraphId
        case .todo(let task): return task.anchor?.paragraphId
        }
    }

    /// True for a sidecar strain only: the next check replaces the standing
    /// check's strains wholesale. A check-minted NOTE lasts until settled.
    var isReplacedByTheNextCheck: Bool {
        switch self {
        case .finding: return true
        case .note, .todo: return false
        }
    }
}
