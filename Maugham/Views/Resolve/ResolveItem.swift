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
///
/// An edition's list (shell p4 Task 6) adds four, each with its own lifetime
/// (`lifetimeCaption`), read by `ResolveEditionItems` without a load:
///
/// - a change: a departure of the piece's latest finished round in a
///   language that nobody has settled (`EditionStatusRows.isToLookAt`) —
///   replaced by the piece's next round;
/// - a glossary proposal of that round, neither adopted nor skipped — the
///   same lifetime;
/// - a design proposal still pending — replaced by the next design round;
/// - a problem the last compile reported — replaced by the next compile.
enum ResolveItem: Identifiable, Equatable {
    case note(ProjectAnnotation)
    case finding(docId: String, Diagnostic)
    case todo(WriterTask)
    case translationChange(docId: String, language: String, round: Int,
                           TranslationRound.DepartureRecord)
    /// `index` is the proposal's place in `round.glossaryProposals`, which is
    /// what the round report's Adopt and Skip file against (the records carry
    /// no id).
    case glossaryProposal(docId: String, language: String, round: Int, index: Int,
                          TranslationRound.GlossaryProposalRecord)
    case designProposal(DesignProposalStore.Proposal)
    case compileProblem(TectonicLogParser.Diagnostic)

    /// Kind-prefixed and document-qualified, so a note, a finding and a to-do
    /// never collide, nor two kinds' ids minted in two documents.
    var id: String {
        switch self {
        case .note(let note): return "note:\(note.docId)/\(note.annotation.id)"
        case .finding(let docId, let finding): return "finding:\(docId)/\(finding.id)"
        case .todo(let task): return "todo:\(docId)/\(task.id)"
        case .translationChange(let docId, let language, let round, let departure):
            return "change:\(language)/\(docId)#\(round)/\(departure.id)"
        case .glossaryProposal(let docId, let language, let round, let index, _):
            return "glossary:\(language)/\(docId)#\(round)/\(index)"
        case .designProposal(let proposal): return "design:\(proposal.id)"
        case .compileProblem(let problem):
            // A problem carries no id; its fields are what tell two apart
            // (`ResolveEditionItems.items` drops exact repeats).
            return "compile:\(problem.level.rawValue)/\(problem.pieceID ?? "")/"
                + "\(problem.paragraphID ?? "")/\(problem.bodyLanguage ?? "")/"
                + "\(problem.line.map(String.init) ?? "")/\(problem.message)"
        }
    }

    /// The document the item belongs to. A to-do with no anchor is the
    /// Book's: `ProjectStore.projectTasksDocId` — and so are a design
    /// proposal and a compile's problem, which are about the whole book.
    var docId: String {
        switch self {
        case .note(let note): return note.docId
        case .finding(let docId, _): return docId
        case .todo(let task): return task.anchor?.docId ?? ProjectStore.projectTasksDocId
        case .translationChange(let docId, _, _, _), .glossaryProposal(let docId, _, _, _, _):
            return docId
        case .designProposal, .compileProblem: return ProjectStore.projectTasksDocId
        }
    }

    /// The paragraph the item points at, when it points at one.
    var paragraphId: String? {
        switch self {
        case .note(let note): return note.annotation.paragraphId
        case .finding(_, let finding): return finding.anchor?.paragraphId
        case .todo(let task): return task.anchor?.paragraphId
        case .translationChange(_, _, _, let departure): return departure.paragraphId
        case .glossaryProposal, .designProposal, .compileProblem: return nil
        }
    }

    /// True for a sidecar strain only: the next check replaces the standing
    /// check's strains wholesale. A check-minted NOTE lasts until settled.
    var isReplacedByTheNextCheck: Bool {
        switch self {
        case .finding: return true
        case .note, .todo, .translationChange, .glossaryProposal, .designProposal,
             .compileProblem: return false
        }
    }

    /// True for the kinds a later run replaces wholesale — a check's strain,
    /// a round's changes and glossary proposals, a design round's proposal, a
    /// compile's problems. A note or a to-do lasts until it is settled.
    var isReplacedByALaterRun: Bool {
        switch self {
        case .finding, .translationChange, .glossaryProposal, .designProposal, .compileProblem:
            return true
        case .note, .todo:
            return false
        }
    }
}
