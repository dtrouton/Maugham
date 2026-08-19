import Foundation
import MaughamCore

/// What a ruling refused to do, in the writer's words.
///
/// The two an append had — nothing to say, and a destination that cannot be
/// read — plus the two a *stratum* has that a free append did not: a verb aimed
/// at a line, and a line that is not there. The same restraint applies —
/// everything the store already refuses in its own
/// vocabulary (an id naming nothing in this project, a `(kind, scope)` with no
/// storage, a file system that would not take the file) propagates as
/// `ProjectStoreError` rather than being re-said here in a second sentence that
/// can drift from the one every other surface shows.
enum RulingFailure: LocalizedError, Equatable {
    /// Return pressed in an untouched field, or an edit that would empty a
    /// ruling. Nothing is minted for either.
    case emptyRuling
    /// The statement exists, its words live in its bytes, and those bytes will
    /// not decode — see `RulingPerformer.refuseIfTheWordsCannotBeRead`.
    case unreadableDestination(String)
    /// Revoke or edit against a scope that has never had a statement. There is
    /// nothing to take a line out of, and minting one to say so would leave a
    /// file behind for a refusal.
    case noStatement
    /// The statement is there and does not carry this ruling — hand-edited
    /// away, revoked in another window, or the row's id has gone stale under a
    /// re-parse. **Loud rather than silent**: `RulingsSection.removing` returns
    /// its input unchanged for an unknown id, so a performer that passed that
    /// through would report a revocation that never happened.
    case unknownRuling(String)

    var errorDescription: String? {
        switch self {
        case .emptyRuling:
            return "A ruling needs something to say."
        case .unreadableDestination(let path):
            return "Maugham could not read what is already in \(path), so it did not "
                + "write your ruling over it."
        case .noStatement:
            return "There is nothing here to rule on yet."
        case .unknownRuling:
            return "That ruling is no longer in this statement."
        }
    }
}

/// **The only door into the writer-owned layer** (second-draft spec §3.4).
///
/// Three verbs — *rule*, *revoke*, *edit* — each taking the writer's words as a
/// `String` and putting them into the intent statement's `## Rulings` stratum
/// through its op log. Because a statement is an op-logged `Document`, **History
/// shows when a ruling was made and Rewind shows the declared world as of any
/// draft** (§3.2), both for free.
///
/// **⌘Z reaches a ruling from the ROWS, and nowhere else** (Task 6). Saying it
/// worked before anything registered an inverse was this file's first defect, so
/// the boundary is worth stating precisely rather than softening again:
///
/// - Nothing here registers anything. The write goes through
///   `Document.setFullText`, which arms no `_undoCoherentApplyPending` and hands
///   `OpUndoRegistrar` nothing. What each verb guarantees is the
///   **precondition** — exactly ONE op carrying its own prior text.
/// - `RulingsStratum` is what turns that into a ⌘Z: it calls a verb, and on
///   success registers the opposite verb against the window's `UndoManager`
///   through `OpUndoRegistrar`. So a ruling revoked or edited **from a row** is
///   one undo step, and one landing from a run or a promotion is not — there is
///   no gesture of the writer's for a ⌘Z to reverse, and an entry on their undo
///   stack for something they did not do is worse than none.
/// - The pane's native typing stack is no longer collateral. It used to be:
///   `EditorSurface.updateNSView` reconciled the changed statement text through
///   `applyExternalText`'s `!preserveUndoStack` branch and *cleared* the
///   writer's typing actions. The Intent pane's editor now binds the ESSAY half
///   (`StatementEssay`), and a ruling does not change the essay — so the buffer
///   is not replaced, and there is nothing to clear.
///
/// **Bless and correct are not verbs here, deliberately.** Spec §3.3 gives the
/// bible stratum three actions and two of them graduate an entry into the
/// writer's layer — but they graduate it as *the writer's act on visible text*,
/// which on the wire is `rule` with a provenance line saying where the sentence
/// came from. A `bless(_ fact: BibleFact)` would be a route by which Claude's
/// reading became the writer's declaration with nothing in between, and the
/// membrane is precisely that no such route exists.
/// `RulingPerformerTests.test_nothingDerivedCanWriteItself` is the census that
/// says so, with a planted `bless(fact:)` as its control.
///
/// **Validate first, write second.** A refused act leaves nothing behind — no
/// minted statement, no op, no half-written file. On a path whose destination
/// already holds the writer's words that is constitution must #1, not a
/// preference.
///
/// **Two destinations, and the kind is explicit and undefaulted** (publish
/// department, Task 6). Rulings are a stratum of the writer's declared layer,
/// and that layer now has two addresses: the **intent** statement (§3.2/§3.3 —
/// the Intent pane is the declared world's one surface) and an **edition
/// brief**, where the decisions governing one language edition are settled.
/// Both are the writer's own prose in the open, both carry a `## Rulings`
/// stratum, and one performer serves both rather than a second spelling
/// serving the second.
///
/// Visual language is a statement too and still has no rulings — nothing mints
/// one for it, because the destination is named by the caller and no caller
/// names that kind. That is what the old "the kind is always `.intent`" note
/// was protecting, and it is protected here by the same fact it always was: a
/// `## Rulings` section appears where a verb puts one.
///
/// The parameter is undefaulted for `world`'s reason, one step sharper. A
/// default would have to be `.intent`, and an edition-side call site that
/// skipped it would file a Spanish edition's decision in the book's own intent
/// — where every language is then checked against it, silently, with nothing
/// red. `RulingPerformerTests.test_everyVerbTakesTheDestinationKindExplicitly`
/// is the census.
///
/// **What it deliberately does NOT do, and why**, since `PromotionPerformer`
/// does both: no autosave flush (a write to a statement goes through its op log,
/// which has no read-back-and-rewrite step to be raced, and a statement is in no
/// `DocumentStore` registry, so `flushPendingSave` could not be flushing this
/// destination) and no project-scope fallback (a ruling made about a chapter and
/// quietly filed under the book is the M1A craft-intent defect arriving through
/// a new door — one chapter's decision read by every other chapter's run). An
/// edition brief being project-scope is not that fallback and never triggers it:
/// project scope is the brief's own address, written by the caller, not somewhere
/// a document-scoped ruling was quietly redirected to. Both
/// arguments were made at length by the M2 answer performer this replaced
/// (`IntentAppendPerformer`, deleted with the run-rebuilt stage); they are
/// unchanged and they live here now, because a rule whose reasoning is only in
/// a deleted file is a rule with no reason.
///
/// **No canvas undo bracket applies.** This writes a statement, not the scene,
/// so tripwire 32's census does not name this file and must not — that census is
/// over `CanvasModel` mutations. The statement's own ops carry the writer's undo
/// through `Document`.
@MainActor
enum RulingPerformer {

    // MARK: - rule

    /// Add one ruling to the `(kind, scope)` statement, minting it if this is
    /// the first thing anyone has declared about this piece or this edition.
    ///
    /// `provenance` is the free suffix after the em-dash — *"from a run on
    /// ¶wnse"*, *"blessed from the bible"* — and the date is stamped here rather
    /// than passed in, because a ruling is dated when it is made.
    ///
    /// `world` is the derivation cache to drop, and it is **explicit and
    /// undefaulted** on all three verbs on purpose: a reading that outlived the
    /// prose it was made from checks the writer against a world they have just
    /// changed, and the symptom surfaces a run later with nothing red. A
    /// defaulted parameter would let a new call site skip it in silence; `nil`
    /// has to be written and meant.
    static func rule(_ text: String, provenance: String, kind: Statement.Kind,
                     forScope scope: Statement.Scope,
                     store: ProjectStore, world: DeclaredWorldStore?) async throws {
        let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty else { throw RulingFailure.emptyRuling }

        // Validated BEFORE the mint, which is what makes a refusal cost
        // nothing: an existing statement is the only thing that can be
        // unreadable, and one about to be created is a zero-byte file with no
        // words in it to lose.
        if let existing = store.statement(kind: kind, scope: scope) {
            try refuseIfTheWordsCannotBeRead(existing, in: store)
        }

        // Find-or-create, idempotent, and the ONLY minting path — M1A built it
        // and every other statement writer uses it. A second spelling would be a
        // second answer to "where does a chapter's intent live".
        let statement = try await store.createStatement(kind: kind, scope: scope)
        let now = Date()
        // One op, carrying its own prior text. The inverse — when this call is
        // a writer's gesture rather than a run's arrival — is registered by
        // `RulingsStratum`, never here; see the type doc.
        try await store.mutateStatementText(of: statement, session: session) { markdown in
            RulingsSection.appending(words, provenance: provenance, on: now, to: markdown)
        }
        invalidate(scope, in: world)
    }

    // MARK: - revoke

    /// Delete exactly the one ruling `rulingId` names. The essay above it and
    /// every other ruling are untouched, and revoking the last one leaves an
    /// essay-only file rather than a heading over nothing (`RulingsSection`).
    static func revoke(rulingId: String, kind: Statement.Kind,
                       forScope scope: Statement.Scope,
                       store: ProjectStore, world: DeclaredWorldStore?) async throws {
        try await mutate(kind, scope, store: store, world: world) { markdown in
            guard RulingsSection.parse(markdown).rulings
                .contains(where: { $0.id == rulingId }) else {
                throw RulingFailure.unknownRuling(rulingId)
            }
            return RulingsSection.removing(rulingId: rulingId, from: markdown)
        }
    }

    // MARK: - edit

    /// Change what one ruling says, **in place**.
    ///
    /// **One op — which is the precondition for one undo step, not the same
    /// claim.** The brief called this remove-plus-append; expressed as a single
    /// whole-text transform it is one `setFullText` and therefore one op
    /// carrying the whole correction's prior text, so whatever eventually
    /// registers an inverse has exactly one thing to reverse. Two ops would
    /// already have cost the writer two ⌘Z presses for one act and no later task
    /// could fix that. **No manual undo group is opened**, and that stays right
    /// even once undo is wired: a group around a single registration is ceremony
    /// with a false reason, and ADR 0023's own warning is that grouping state is
    /// the thing that corrupts. See the type doc for why ⌘Z reaches none of this
    /// today.
    ///
    /// **In place rather than remove-then-append, which would move the line to
    /// the bottom of the list.** A correction is a fix to a decision already
    /// made, not a new decision: the ruling keeps its position, the day it was
    /// ruled, and its provenance. A writer whose mind changed revokes and rules
    /// again, and gets today's date for it — which is the honest record.
    ///
    /// The rendering goes through `RulingsSection.render`, never hand-built
    /// markdown.
    static func edit(rulingId: String, newText: String, kind: Statement.Kind,
                     forScope scope: Statement.Scope,
                     store: ProjectStore, world: DeclaredWorldStore?) async throws {
        let words = newText.trimmingCharacters(in: .whitespacesAndNewlines)
        // An edit that empties a ruling is a revocation wearing the wrong verb,
        // and silently performing one would delete a line the writer meant to
        // correct.
        guard !words.isEmpty else { throw RulingFailure.emptyRuling }

        try await mutate(kind, scope, store: store, world: world) { markdown in
            let (essay, rulings) = RulingsSection.parse(markdown)
            guard let index = rulings.firstIndex(where: { $0.id == rulingId }) else {
                throw RulingFailure.unknownRuling(rulingId)
            }
            var updated = rulings
            // `id` is derived from the line's text at parse time and is never
            // stored in the file, so the placeholder here is what `render`
            // already expects (`RulingsSection.appending` passes the same).
            updated[index] = Ruling(
                id: "", text: words,
                ruledOn: rulings[index].ruledOn, provenance: rulings[index].provenance)
            return RulingsSection.render(essay: essay, rulings: updated)
        }
    }

    // MARK: - restore

    /// Put a revoked ruling back exactly as it was — **the fourth verb, and it
    /// exists only so ⌘Z can be honest.**
    ///
    /// `rule` would have served as the inverse of `revoke` and would have been
    /// wrong in a way nobody would notice for months: it stamps `Date()` and
    /// appends at the end, so undoing the revocation of a decision made in March
    /// would give it back dated today, at the bottom of the list. An undo that
    /// rewrites the record is worse than no undo, because the record is what the
    /// writer is checked against. This restores the position, the day it was
    /// ruled and the provenance the line already carried.
    ///
    /// **It is not a second door into the writer's layer** (§3.4). The `Ruling`
    /// it takes is one a `revoke` on this same statement just produced — a value
    /// from the writer's own layer on its way back into it, never a reading. The
    /// membrane census (`RulingPerformerTests.test_nothingDerivedCanWriteItself`)
    /// covers this verb with the other three; a `restore(_ fact: BibleFact)`
    /// would fail it exactly as `bless` does.
    ///
    /// An `index` past the end lands at the end rather than refusing: the list
    /// can legitimately have shrunk since (a peer's revoke, a hand edit), and a
    /// refusal there would lose the line the writer is asking for back.
    static func restore(_ ruling: Ruling, at index: Int, kind: Statement.Kind,
                        forScope scope: Statement.Scope,
                        store: ProjectStore, world: DeclaredWorldStore?) async throws {
        try await mutate(kind, scope, store: store, world: world) { markdown in
            let (essay, rulings) = RulingsSection.parse(markdown)
            var updated = rulings
            updated.insert(ruling, at: min(max(index, 0), rulings.count))
            return RulingsSection.render(essay: essay, rulings: updated)
        }
    }

    // MARK: - The shared half of revoke and edit

    /// Both line verbs need the same three things: a statement that already
    /// exists (neither may mint one — there is no line to act on in a file
    /// nobody has written), words that can be read before they are written
    /// over, and the cache dropped once the write has landed.
    ///
    /// `transform` runs against the text the write is made from, so the
    /// "is this ruling still here" check and the edit are decided over one
    /// string — see `ProjectStore.mutateStatementText`.
    private static func mutate(
        _ kind: Statement.Kind, _ scope: Statement.Scope,
        store: ProjectStore, world: DeclaredWorldStore?,
        _ transform: (String) throws -> String
    ) async throws {
        guard let statement = store.statement(kind: kind, scope: scope) else {
            throw RulingFailure.noStatement
        }
        try refuseIfTheWordsCannotBeRead(statement, in: store)
        // One op each, and the inverse each needs is its own — `RulingsStratum`
        // registers it when the act was a writer's gesture (see the type doc).
        try await store.mutateStatementText(
            of: statement, session: session, transform: transform)
        invalidate(scope, in: world)
    }

    // MARK: - The cache the prose outran

    /// Drop the reading for this scope, through **the one scope-key spelling**
    /// (`DeclaredWorldStore.scopeKey(for:)`) rather than formatting the scope
    /// here: two spellings mean two caches and one of them is never hit.
    ///
    /// Called only after a write has landed. Invalidating on a refusal would
    /// spend a spawn and a fistful of tokens re-deriving a statement nothing
    /// moved.
    ///
    /// **The key is the scope alone, and the destination kind is deliberately
    /// not in it** (publish department, Task 6). Nothing derives a world from an
    /// edition brief — the cache holds intent readings only, and every
    /// brief-side caller passes `world: nil`, so the widened verbs bring the
    /// cache no new writers. Adding the kind to the key today would be a second
    /// spelling of a key with one shape, which is exactly what the one-spelling
    /// rule above exists to prevent; the day a brief is derived is the day
    /// `DeclaredWorldStore` grows the kind, in one place, for both readers.
    private static func invalidate(_ scope: Statement.Scope, in world: DeclaredWorldStore?) {
        world?.invalidate(forScopeKey: DeclaredWorldStore.scopeKey(for: scope))
    }

    // MARK: - must #1

    /// Refuse when the statement's words are in its BYTES and those bytes will
    /// not decode.
    ///
    /// **Scoped exactly to the case where the loss is real, and the scope is the
    /// whole point.** `Document.load` reads the file with
    /// `(try? String(contentsOf:encoding:.utf8)) ?? ""` and bootstraps from what
    /// it gets — so for a statement with NO op log an undecodable file bootstraps
    /// as empty, the write lands, and the writer's stated intent is gone with
    /// nothing red anywhere.
    ///
    /// When an op log DOES exist the same load ignores the file entirely (ADR
    /// 0019: the op log is authoritative and the `.md` is derived output the next
    /// render rewrites), so refusing there would block the writer over a file
    /// Maugham does not read as truth — a rule with a false reason, which this
    /// codebase treats as worse than no rule. `OpLogStore.opLogFileURLs` is asked
    /// here because it is the same predicate `Document.load` branches on.
    ///
    /// An ABSENT file is legitimately empty — a freshly minted statement is zero
    /// bytes by design — so absence is not a refusal.
    private static func refuseIfTheWordsCannotBeRead(
        _ statement: Statement, in store: ProjectStore
    ) throws {
        guard OpLogStore.opLogFileURLs(forDocId: statement.id, in: store.url).isEmpty
        else { return }
        let url = store.url.appendingPathComponent(statement.path)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        guard (try? String(contentsOf: url, encoding: .utf8)) != nil else {  // adr-0018-ok: a reachability probe on a statement's BOOTSTRAP bytes, guarded above on there being no op log — the exact read `Document.load` makes in that case, asked here so an undecodable file is a refusal rather than a silent empty
            throw RulingFailure.unreadableDestination(statement.path)
        }
    }

    /// Session id for the ops a ruling writes when no pane has the statement
    /// open. Stable for the launch, like every other session stamp
    /// (`PromotionPerformer.promotionSession`).
    private static let session = "ruling-\(UUID().uuidString)"
}
