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
///
/// And one kind the figure cards answer (shell p5 Task 3, `ResolveFigureChange`):
/// a figure whose source data changed, listed on each piece placing it (at
/// its line's paragraph where the read holds the piece's text), the Book's
/// when no piece does, the figure's own at its scope — until the pin is
/// current again.
enum ResolveItem: Identifiable, Equatable {
    case note(ProjectAnnotation)
    case finding(docId: String, Diagnostic)
    case todo(WriterTask)
    case translationChange(docId: String, language: String, round: Int,
                           TranslationRound.DepartureRecord)
    /// Named by the record's `identity` (term and rendering), which the
    /// verbs resolve against the stored round — never a position.
    case glossaryProposal(docId: String, language: String, round: Int,
                          TranslationRound.GlossaryProposalRecord)
    case designProposal(DesignProposalStore.Proposal)
    case compileProblem(TectonicLogParser.Diagnostic)
    /// `docId`: the piece placing the figure; nil for an unused one (the
    /// Book's); the figure's own id at its own scope.
    case figureSourceChanged(figureId: String, docId: String?, paragraphId: String?)

    /// Kind-prefixed and document-qualified, so a note, a finding and a to-do
    /// never collide, nor two kinds' ids minted in two documents.
    var id: String {
        switch self {
        case .note(let note): return "note:\(note.docId)/\(note.annotation.id)"
        case .finding(let docId, let finding): return "finding:\(docId)/\(finding.id)"
        case .todo(let task): return "todo:\(docId)/\(task.id)"
        case .translationChange(let docId, let language, let round, let departure):
            return "change:\(language)/\(docId)#\(round)/\(departure.id)"
        case .glossaryProposal(let docId, let language, let round, let proposal):
            return "glossary:\(language)/\(docId)#\(round)/\(proposal.identity)"
        case .designProposal(let proposal): return "design:\(proposal.id)"
        case .compileProblem(let problem):
            // A problem carries no id; its fields are what tell two apart
            // (`ResolveEditionItems.items` drops exact repeats).
            return "compile:\(problem.level.rawValue)/\(problem.pieceID ?? "")/"
                + "\(problem.paragraphID ?? "")/\(problem.bodyLanguage ?? "")/"
                + "\(problem.line.map(String.init) ?? "")/\(problem.message)"
        case .figureSourceChanged(let figureId, _, _):
            return "figure-source:\(docId)/\(figureId)"
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
        case .translationChange(let docId, _, _, _), .glossaryProposal(let docId, _, _, _):
            return docId
        case .figureSourceChanged(_, let docId?, _): return docId
        case .designProposal, .compileProblem, .figureSourceChanged(_, nil, _):
            return ProjectStore.projectTasksDocId
        }
    }

    /// The paragraph the item points at, when it points at one.
    var paragraphId: String? {
        switch self {
        case .note(let note): return note.annotation.paragraphId
        case .finding(_, let finding): return finding.anchor?.paragraphId
        case .todo(let task): return task.anchor?.paragraphId
        case .translationChange(_, _, _, let departure): return departure.paragraphId
        case .figureSourceChanged(_, _, let paragraphId): return paragraphId
        case .glossaryProposal, .designProposal, .compileProblem: return nil
        }
    }

    /// True for a sidecar strain only: the next check replaces the standing
    /// check's strains wholesale. A check-minted NOTE lasts until settled.
    var isReplacedByTheNextCheck: Bool {
        switch self {
        case .finding: return true
        case .note, .todo, .translationChange, .glossaryProposal, .designProposal,
             .compileProblem, .figureSourceChanged: return false
        }
    }
}
