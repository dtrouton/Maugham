import Foundation
import MaughamCore

/// **The one place a proposal's words reach a statement** (translation
/// pipeline spec §10; ADR 0030 §7). A proposal is staged by an MCP tool and
/// waits in `StatementProposalStore`; this runs when the WRITER presses Adopt
/// in `StatementPane`. It is a writer's act, which is why it may write.
///
/// Adopt does three things, in order, and each is an existing verb:
/// 1. find-or-create the statement (`ProjectStore.createStatement`, the only
///    minting path — a first Adopt on a language with no brief creates it);
/// 2. replace the ESSAY through `ProjectStore.mutateStatementText`. A brief
///    (and intent, though nothing proposes one) has strata beneath its essay
///    (`StatementEssay.carriesRulings`), so the write goes through
///    `StatementEssay.recomposed` and the `## Rulings` tail is byte-identical.
///    A visual language has no strata at all — the whole file IS the essay —
///    so the write there replaces the whole text outright rather than asking
///    `recomposed` to preserve a tail that only *looks* like a Rulings
///    section because the writer once typed a heading of their own;
/// 3. append each glossary line through `RulingPerformer.rule` with
///    `Ruling.Provenance.glossary` — the same door every ruling uses, so the
///    section renders canonically exactly as a Make-it-a-rule would.
///
/// The essay write is ONE op, and the undo registered here is one step over
/// the whole adoption (essay + glossary): ⌘Z puts `before` back whole. A
/// first Adopt that created the statement undoes to an EMPTY statement, not
/// to no statement — `rollbackUnusedStatement`'s job, and a statement with a
/// manifest row and no words is the same state a pane visit leaves.
///
/// **A refusal writes nothing and mints nothing**: the proposal is re-validated
/// BEFORE `createStatement`, because the slot is a plain JSON file anyone can
/// hand-edit, and the P1 carry (an empty glossary term must never be written)
/// is enforced here as well as at the tool.
@MainActor
enum StatementProposalGate {

    struct Adoption: Equatable {
        let statement: Statement
        let created: Bool
        let glossaryAppended: Int
        let before: String
        let after: String
    }

    enum Failure: Error, Equatable, CustomStringConvertible {
        case proposalGone
        case refused(StatementProposalStore.ProposalRefusal)
        case unreadable(String)

        var description: String {
            switch self {
            case .proposalGone: return "That proposal is no longer pending — it was superseded or discarded."
            case .refused(let refusal): return refusal.description
            case .unreadable(let why): return "Couldn’t read the statement: \(why)"
            }
        }
    }

    /// The essay Adopt writes: a brief's prose above its (proposed) rulings;
    /// a visual language whole.
    static func adoptedEssay(proposalMarkdown: String, kind: ProposableStatement) -> String {
        guard StatementEssay.carriesRulings(kind.statementKind) else { return proposalMarkdown }
        return StatementEssay.half(of: proposalMarkdown)
    }

    static func adopt(_ proposal: StatementProposalStore.Proposal, store: ProjectStore,
                      world: DeclaredWorldStore?, undoManager: UndoManager?,
                      workTaskSink: @escaping (Task<Void, Never>) -> Void) async throws -> Adoption {
        let proposals = StatementProposalStore(projectURL: store.url)
        guard proposals.pending(for: proposal.kind) == proposal else { throw Failure.proposalGone }
        // `validate` is typed-throws (`throws(ProposalRefusal)`); the catch
        // below is deliberately UNTYPED rather than `catch let refusal as
        // StatementProposalStore.ProposalRefusal` — the `as`-pattern form
        // over a typed-throwing call crashes this toolchain's SILGen
        // ownership verifier (isolated by removing pieces of this function
        // until the crash disappeared; the plain `catch` relies on Swift's
        // typed-throw inference to give `error` the same concrete type).
        do {
            try StatementProposalStore.validate(kind: proposal.kind, markdown: proposal.markdown)
        } catch {
            throw Failure.refused(error)
        }
        let kind = proposal.kind.statementKind
        let glossary = glossaryEntries(in: proposal)

        let created = store.statement(kind: kind, scope: .project) == nil
        let statement = try await store.createStatement(kind: kind, scope: .project)
        let before: String
        do { before = try store.statementText(of: statement) }
        catch { throw Failure.unreadable(error.localizedDescription) }

        try await writeEssay(of: proposal, to: statement, store: store)
        for entry in glossary {
            try await RulingPerformer.rule(
                Ruling.glossaryText(term: entry.term, rendering: entry.rendering, note: entry.note),
                provenance: Ruling.Provenance.glossary,
                kind: kind, forScope: .project, store: store, world: world)
        }
        let after = (try? store.statementText(of: statement)) ?? ""
        try proposals.discard(proposal.kind)
        MaughamEvent.postStatementProposalsChanged(projectURL: store.url)

        registerUndo(undoManager, statement: statement, before: before, after: after,
                    store: store, workTaskSink: workTaskSink)
        return Adoption(statement: statement, created: created, glossaryAppended: glossary.count,
                        before: before, after: after)
    }

    static func discard(_ kind: ProposableStatement, store: ProjectStore) throws {
        try StatementProposalStore(projectURL: store.url).discard(kind)
        MaughamEvent.postStatementProposalsChanged(projectURL: store.url)
    }

    // MARK: - private

    /// The glossary rows a brief's proposal carries, or none for a visual
    /// language (which has no rulings section at all — Task 1's `validate`
    /// already refuses one that tries).
    private static func glossaryEntries(
        in proposal: StatementProposalStore.Proposal
    ) -> [(term: String, rendering: String, note: String?)] {
        guard case .editionBrief = proposal.kind else { return [] }
        return (try? StatementProposalStore.glossaryLines(in: proposal.markdown)) ?? []
    }

    /// Replace `statement`'s essay with the proposal's, split out of `adopt`
    /// on its own so the branch between the two kinds of statement — one
    /// with strata beneath its essay, one without — is a single small
    /// function rather than a condition folded into a much larger one.
    ///
    /// **Why the branch exists at all.** A brief (and intent, though nothing
    /// proposes one) carries a `## Rulings` stratum beneath its essay
    /// (`StatementEssay.carriesRulings`), so the write goes through
    /// `StatementEssay.recomposed` and the tail below that stratum is kept
    /// byte-identical. A visual language has no strata — the whole file IS
    /// the essay — so the write there replaces the whole text outright:
    /// asking `recomposed` to preserve a tail would trust a `## Rulings`
    /// heading the writer merely typed as ordinary prose, with something
    /// parseable under it, as if it were a real stratum boundary and keep it
    /// across the replace (`test_adoptingAVisualLanguageReplacesTheWholeText`).
    private static func writeEssay(
        of proposal: StatementProposalStore.Proposal, to statement: Statement, store: ProjectStore
    ) async throws {
        let essay = adoptedEssay(proposalMarkdown: proposal.markdown, kind: proposal.kind)
        guard StatementEssay.carriesRulings(proposal.kind.statementKind) else {
            try await store.mutateStatementText(of: statement, session: session) { _ in essay }
            return
        }
        try await store.mutateStatementText(of: statement, session: session) { existing in
            StatementEssay.recomposed(essay: essay, into: existing)
        }
    }

    /// One undo step over the WHOLE adoption (essay + every glossary
    /// ruling): ⌘Z puts `before` back whole, redo puts `after` back whole —
    /// never a replay of the individual ops each step wrote.
    private static func registerUndo(
        _ undoManager: UndoManager?, statement: Statement, before: String, after: String,
        store: ProjectStore, workTaskSink: @escaping (Task<Void, Never>) -> Void
    ) {
        OpUndoRegistrar.register(
            undoManager, actionName: StatementProposalCopy.undoActionName, target: store,
            workTaskSink: workTaskSink,
            undo: { s in
                try? await s.mutateStatementText(of: statement, session: session) { _ in before }
            },
            redo: { s in
                try? await s.mutateStatementText(of: statement, session: session) { _ in after }
            })
    }

    private static let session = "proposal-\(UUID().uuidString)"
}

/// Every sentence the gate says, as statics — assertable with nothing mounted.
enum StatementProposalCopy {
    static let adoptTitle = "Adopt"
    static let discardTitle = "Discard"
    static let rationaleHeading = "Why"
    static let diffHeading = "Against your current text"
    static let noCurrentTextLine = "Nothing to compare — this statement is empty."
    static let discardedLine = "Proposal discarded."
    static let undoActionName = "Adopt Proposal"
    static let discardHelp = "Clear this proposal. Nothing you wrote changes."

    static func bannerTitle(_ proposal: StatementProposalStore.Proposal) -> String {
        "\(proposal.author) proposed a \(proposal.kind.displayName)"
    }

    static func bannerWhen(_ date: Date, now: Date) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        if seconds < 60 { return "just now" }
        let minutes = Int(seconds / 60)
        if minutes < 60 { return "\(minutes) minute\(minutes == 1 ? "" : "s") ago" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours) hour\(hours == 1 ? "" : "s") ago" }
        let days = hours / 24
        return "\(days) day\(days == 1 ? "" : "s") ago"
    }

    static func adoptHelp(_ kind: ProposableStatement) -> String {
        switch kind {
        case .editionBrief:
            return "Replace the prose of this brief with the proposal. Your rulings stay exactly "
                + "as they are; the proposal's glossary entries are added below them. One ⌘Z takes it back."
        case .visualLanguage:
            return "Replace this statement with the proposal. One ⌘Z takes it back."
        }
    }
    static func adoptAccessibilityLabel(_ kind: ProposableStatement) -> String {
        "Adopt the proposed \(kind.displayName)"
    }
    static func discardAccessibilityLabel(_ kind: ProposableStatement) -> String {
        "Discard the proposed \(kind.displayName)"
    }
    static func adoptedLine(glossary: Int) -> String {
        guard glossary > 0 else { return "Adopted." }
        return "Adopted, with \(glossary) glossary entr\(glossary == 1 ? "y" : "ies")."
    }
    static func firstAdoptCreatesLine(_ kind: ProposableStatement) -> String {
        "There is no \(kind.displayName) yet — Adopt creates it."
    }
    static func glossaryLine(count: Int) -> String? {
        guard count > 0 else { return nil }
        return "Carries \(count) glossary entr\(count == 1 ? "y" : "ies"), appended as rulings on Adopt."
    }
}
