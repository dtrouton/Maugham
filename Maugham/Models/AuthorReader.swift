import Foundation
import MaughamCore

/// **Who reads a CHECK** — Author's ⌘R, and every persona's but Review's
/// (two loops P1, spec §2 "The check and the round part ways").
///
/// The coach, the writer's own first reader, or nobody — and which of the
/// three is the writer's choice, resolved in exactly one place below. The
/// pass a piece sits in on the review board is not among the inputs: that is
/// a fact about the ROUND loop, and `PieceReader` — the one resolution this
/// type replaces — answered *stage / coach / nobody* for both verbs, which is
/// how a chapter parked in Gould's lane came to have its Author checks signed
/// "Gould" and filed as rounds in a lane the writer was not standing in.
///
/// **There is no stage arm, and no `ActivePassMemory` is read here.** A
/// second arm would be the defect coming back, so the absence is guarded
/// rather than merely intended: `TripwireGrepTests`' census fails if this
/// file so much as names the memory. Who reads a round is `RoundEditor`'s
/// question, one file over.
///
/// **`nobody` is M2's lane and nothing else.** No `ActivePass` at all is what
/// `CompilerOrchestrator` reads as the passless run: no round number, no pass
/// stamp on what it writes, notes signed
/// `CompilerOrchestrator.passlessEditorName`. That constant's ONE production
/// use is this enum's `nobody` arm (`TripwireGrepTests`' census) — the mint
/// site reads `AuthorReader.nobody.editorName` rather than the constant, so
/// there is one place that decides what an unread piece's notes are signed.
///
/// Lives in the Mac app rather than MaughamCore because the resolution it
/// belongs to — the pair with `RoundEditor` — reads the Mac's own UI state on
/// the other side.
enum AuthorReader: Equatable {
    /// The coach, holding her seat. Every piece is hers while it is held:
    /// the check loop does not ask which lane a piece is parked in.
    case coach(ReviewPass)
    /// The writer's own first reader — a person they named, not a persona the
    /// app supplies. She is a `FirstReader` rather than a `ReviewPass`
    /// because she has no doctrine and no lane: she has a name and, if the
    /// writer has written one, a description of who she is.
    case firstReader(FirstReader)
    /// Nobody: the writer chose nobody, or there is nobody to choose. M2's
    /// all-altitudes ⌘R.
    case nobody

    /// What the check is briefed as — `nil` for `nobody`, which is the whole
    /// of the passless case.
    ///
    /// **`isCoach` is unconditionally true here**, because the only arm that
    /// produces one is the coach's. It is what `CompilerPrompt.passSection`
    /// reads to frame her as a teacher rather than an editor, and a check is
    /// the one verb that can ever carry it: a round's `ActivePass` is always
    /// a stage's.
    ///
    /// **`effectiveEditorName`/`effectiveBrief`, never the raw fields** (M4 P1
    /// Task 1's rule): a customized manifest can store a preset-id pass that
    /// predates both, and reading `pass.editorName` here would sign a check's
    /// notes with nothing at all.
    ///
    /// **The first reader answers `nil` here, and that is a placeholder rather
    /// than an answer.** She is not a pass and cannot be squeezed through the
    /// pass-shaped seam — Task 3 briefs her in her own words and Task 4
    /// deletes this property along with its last caller. Until then it keeps
    /// the existing wiring compiling, and a check under her is briefed as the
    /// passless run would be, which is the closest wrong answer available.
    var activePass: CompilerOrchestrator.ActivePass? {
        guard case .coach(let pass) = self else { return nil }
        return CompilerOrchestrator.ActivePass(
            id: pass.id, name: pass.name,
            editorName: pass.effectiveEditorName,
            brief: pass.effectiveBrief,
            isCoach: true)
    }

    /// The byline: who signs this piece's check notes, and whose name the
    /// Author header says. Never nil — an unread piece is still signed, and
    /// "Claude" is the name it is signed with.
    ///
    /// The first reader signs with her own name and nothing else: there is no
    /// `effectiveEditorName` to resolve, because the writer typed the name and
    /// no preset can disagree with it.
    var editorName: String {
        switch self {
        case .coach(let pass): return pass.effectiveEditorName
        case .firstReader(let reader): return reader.name
        case .nobody: return CompilerOrchestrator.passlessEditorName
        }
    }
}

/// The writer's own first reader: a name, and what the writer has written
/// about her.
///
/// **Two fields from two places, deliberately.** The name is manifest
/// identity (`ProjectManifest.firstReaderName`) — it travels with the book and
/// every surface that mentions her renders it. The description is the whole
/// markdown of her statement (`Statement.Kind.firstReader`, `first-reader.md`),
/// read at the keystroke rather than held: it is prose the writer edits in a
/// pane, and a copy cached anywhere would be a second answer to what she
/// knows.
///
/// `statement` is `nil` when the writer has named her and not yet described
/// her — a reader with a name and no description is a valid state (§4.3), and
/// resolving it to `nobody` would silently discard a reader the writer picked.
struct FirstReader: Equatable, Sendable {
    let name: String
    let statement: String?
}

extension ProjectManifest {

    /// **The check's reader, and it is per PROJECT rather than per piece.**
    /// The seat is held over a book, not over a chapter, and there is nothing
    /// else left in the rule — so a `forPiece:` parameter here would be an
    /// argument this resolution could only ignore, and a seam suggesting a
    /// per-piece answer that no longer exists.
    ///
    /// **The choice is a preference and the fallback is the rule.** An
    /// explicit `.coach` answers her only while the seat is held, and
    /// `.firstReader` only while a name is set: a choice whose subject has
    /// gone falls through to the default rule rather than resolving to a
    /// reader who is not there. `.nobody` is the one choice with no premise to
    /// lose, so it always answers. `nil` — the writer has not chosen — is the
    /// default rule itself: the coach while her seat is held, else the first
    /// reader if one is named, else nobody.
    ///
    /// **`statementText` is how her description is loaded without this model
    /// knowing about stores** — production passes
    /// `{ try store.statementText(of: $0) }`, and it is asked only when a
    /// first reader actually resolves, so no other arm pays for a read it will
    /// not use. A throwing reader (RULING-54's unreadable log) leaves her
    /// description empty rather than losing her: the name is manifest metadata
    /// and is still true whatever the log says. Blank prose is the same state
    /// as none, so that a surface cannot render an empty description where it
    /// meant to render no description.
    func authorReader(
        choice: AuthorReaderChoice?,
        statementText: (Statement) throws -> String?
    ) -> AuthorReader {
        func firstReader() -> AuthorReader? {
            // Trimmed here as well as in `ProjectStore.setFirstReaderName`,
            // for the reason `UIState`'s width is clamped on the way in: a
            // hand-edited `project.json` is a writer of this field too, and a
            // reader whose name is a space is a byline nobody can read.
            let name = (firstReaderName ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return nil }
            let statement = StatementLookup.statement(
                in: statements, kind: .firstReader, scope: .project)
            let described = statement
                .flatMap { try? statementText($0) }?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return .firstReader(FirstReader(
                name: name,
                statement: (described?.isEmpty ?? true) ? nil : described))
        }
        func byDefault() -> AuthorReader {
            effectiveCoach.map(AuthorReader.coach) ?? firstReader() ?? .nobody
        }

        switch choice {
        case .coach: return effectiveCoach.map(AuthorReader.coach) ?? byDefault()
        case .firstReader: return firstReader() ?? byDefault()
        case .nobody: return .nobody
        case nil: return byDefault()
        }
    }

    /// The default rule, with no statement text — what the surfaces that only
    /// need the reader's NAME read (the Author header, a byline). It is the
    /// same resolution rather than a second spelling of it: a header naming a
    /// reader the run was not briefed on is the drift this pair exists to
    /// prevent.
    var authorReader: AuthorReader {
        authorReader(choice: nil, statementText: { _ in nil })
    }
}
