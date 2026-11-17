import Foundation

/// **Which loop asked for this run** — a check (Check Writing, Reread) or a
/// round (Run Round, Fresh Eyes, the round cockpit's Run).
///
/// The two verbs were once one act, and then the persona decided which one a
/// keystroke was (two loops P1). Since shell p1 Task 5 the COMMAND names its
/// kind (`RunCommand`): four File menu items, each posting its own, and every
/// other caller of `runRequested` names its kind literally. The kind is
/// carried on `StreamingRun` to the record, so the preview and the answer
/// that supersedes it cannot describe two different verbs.
///
/// **A typed pair rather than a `Bool`.** `isRound` would read as a modifier
/// on one verb; these are two, and the difference between them is about to
/// become what the run is FOR rather than a flag it carries. Adding a third
/// loop is adding a case, and every site that decides on the kind is then the
/// compiler's problem rather than a reviewer's — `Acknowledgment`'s reasoning,
/// one file over.
///
/// `String`-raw and `Codable` because it is stamped on `CompilerRun` and so
/// reaches the per-document sidecar on disk: a rename is a wire change, and
/// `CompilerRun.kind` is optional precisely so a record written before this
/// type existed still decodes (`CompilerRun.effectiveKind` states the legacy
/// rule for those).
///
/// `CaseIterable` because the diagnostics sidecar holds one standing slot per
/// case (two loops P1 Task 5) and has to walk them: a hand-written list of the
/// two would be the one enumeration a third case could not make the compiler
/// complain about.
enum RunKind: String, Codable, Equatable, Sendable, CaseIterable {
    /// Check Writing (⌘R): the delta since the marker, read by the reader,
    /// filed in no lane.
    case check
    /// Run Round (⌃⌘R): the piece whole, read by the pass's editor, filed
    /// as a numbered round in that pass's lane.
    case round
}

/// **The File menu's four run commands, each naming its own kind** (shell p1
/// Task 5). What Run means is a property of the command, never of the window:
/// ⌘R is always a check, wherever the writer is standing, and a round is only
/// ever asked for by name.
///
/// Exhaustive switches with no `default`, so a fifth command must be given a
/// kind, a cold-read answer, a title and an event here rather than inheriting
/// any of them.
enum RunCommand: CaseIterable, Equatable, Sendable {
    /// ⌘R — a check over what changed since the last check.
    case checkWriting
    /// ⇧⌘R — the check read cold: the warm session ends and the piece is read whole.
    case reread
    /// ⌃⌘R — a numbered round by the pass's editor.
    case runRound
    /// ⌃⇧⌘R — the round read cold.
    case freshEyes

    var kind: RunKind {
        switch self {
        case .checkWriting, .reread: return .check
        case .runRound, .freshEyes: return .round
        }
    }

    /// Whether the warm session is retired and the piece read whole.
    var isFreshEyes: Bool {
        switch self {
        case .checkWriting, .runRound: return false
        case .reread, .freshEyes: return true
        }
    }

    /// The File menu's title.
    var title: String {
        switch self {
        case .checkWriting: return "Check Writing"
        case .reread: return "Reread"
        case .runRound: return "Run Round"
        case .freshEyes: return "Fresh Eyes"
        }
    }

    /// The key-window event the menu item posts and `CompilerRunModifier`
    /// answers. One event per command: four promises, and a receiver that
    /// read a flag out of a payload could deliver the expensive one by accident.
    var event: Notification.Name {
        switch self {
        case .checkWriting: return .maughamRunCompiler
        case .reread: return .maughamFreshEyesCompiler
        case .runRound: return .maughamRunRound
        case .freshEyes: return .maughamFreshEyesRound
        }
    }
}
