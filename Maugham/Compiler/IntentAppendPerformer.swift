import Foundation
import MaughamCore

/// What an answer refused to do, in the writer's words.
///
/// Deliberately only TWO cases. Everything the store already refuses in its own
/// vocabulary — an id that names nothing in this project, a `(kind, scope)` with
/// no storage, a file system that would not take the file — propagates as
/// `ProjectStoreError`, which is `LocalizedError` and already says those things
/// better than a translation layer here would. A second spelling of
/// "that item is no longer in the project" is a sentence that can drift from the
/// one every other surface shows.
enum IntentAppendFailure: LocalizedError, Equatable {
    /// Return pressed in an untouched field. Nothing is minted for it.
    case emptyAnswer
    /// The statement exists, its words live in its bytes, and those bytes will
    /// not decode — see `IntentAppendPerformer.refuseIfTheWordsCannotBeRead`.
    case unreadableDestination(String)

    var errorDescription: String? {
        switch self {
        case .emptyAnswer:
            return "There is nothing to add to your intent yet."
        case .unreadableDestination(let path):
            return "Maugham could not read what is already in \(path), so it did not "
                + "write your answer over it."
        }
    }
}

/// **A diagnostic the writer answered becomes intent** (M2 Task 10).
///
/// This is the loop the whole milestone exists for. The compiler raises a note;
/// the writer types *"that's deliberate, because the fog is a refrain"*; those
/// words go into the piece's intent statement, and the NEXT run reads them as
/// part of what the prose is being checked against
/// (`CompilerEnvironment+Project`'s `intent` closure, piece-first). Without the
/// append the compiler asks the same question every run and the writer's answer
/// lives nowhere.
///
/// **`PromotionPerformer`'s shape: validate first, write second.** A refused
/// answer leaves nothing behind — no minted statement, no op, no half-written
/// file. That is not a general preference; on an APPEND path it is constitution
/// must #1, because the destination already holds the writer's words.
///
/// **What it deliberately does NOT do, and why, since the sibling does:**
///
/// - *No autosave flush.* `PromotionPerformer` flushes before every path that
///   reads a file back and writes the whole thing out, because a queued 750 ms
///   `scheduleFileSave` otherwise lands after the write and restores stale
///   content. There is no such window here: an append to a statement goes
///   through its op log, which has no read-back-and-rewrite step to be raced
///   (`ProjectStore.appendToStatement` says so at length), and a statement is
///   deliberately in no `DocumentStore` registry (spec §8), so
///   `flushPendingSave` could not be flushing this destination even if there
///   were something to flush. A flush here would be ceremony with a false
///   reason attached.
/// - *No project-scope fallback.* `PromotionPerformer.intentScope` falls back to
///   `.project` for a piece the router refuses, and that is right for a canvas
///   scrap, which may carry no piece association at all — refusing would cost
///   the writer a promotion that has always worked. A diagnostic is always
///   raised against an open manuscript document, so the piece is never absent;
///   the only way `.document(docId)` is refused here is a doc that is not in
///   this project, and writing THAT answer into the book's intent is the M1A
///   craft-intent defect arriving through a new door — one chapter's
///   explanation read by every other chapter's run. It refuses instead.
///
/// **No canvas undo bracket applies.** This writes a statement, not the scene,
/// so tripwire 32's census (`TripwireGrepTests`
/// `.test_theCanvasUndoBracketIsReachedFromAnotherColumnByOneVerbOnly`) does not
/// name this file and must not — that census is over `CanvasModel` mutations.
/// The statement's own ops carry the writer's undo through `Document`, as every
/// other append into one does.
@MainActor
enum IntentAppendPerformer {

    /// Add the writer's answer to the end of `docId`'s intent statement,
    /// minting the statement if this is the first thing anyone has said about
    /// this piece.
    ///
    /// One paragraph: `appendToStatement` puts a blank line between what is
    /// there and what is arriving, and nothing at all in front of the first
    /// thing to reach an empty statement.
    static func append(answer: String, forDocId docId: String,
                       store: ProjectStore) async throws {
        let words = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty else { throw IntentAppendFailure.emptyAnswer }

        // Validated BEFORE the mint, which is what makes a refusal cost
        // nothing: an existing statement is the only thing that can be
        // unreadable, and a statement about to be created is a zero-byte file
        // with no words in it to lose.
        if let existing = store.statement(kind: .intent, scope: .document(docId)) {
            try refuseIfTheWordsCannotBeRead(existing, in: store)
        }

        // Find-or-create, idempotent, and the ONLY minting path — M1A built it
        // and `PromotionPerformer.performCraftIntent` uses the same call. A
        // second spelling would be a second answer to "where does a chapter's
        // intent live".
        let statement = try await store.createStatement(
            kind: .intent, scope: .document(docId))
        try await store.appendToStatement(words, to: statement, session: session)
    }

    /// Refuse when the statement's words are in its BYTES and those bytes will
    /// not decode.
    ///
    /// **Scoped exactly to the case where the loss is real, and the scope is
    /// the whole point.** `Document.load` reads the file with
    /// `(try? String(contentsOf:encoding:.utf8)) ?? ""` and bootstraps from
    /// what it gets — so for a statement with NO op log, an undecodable file
    /// bootstraps as empty, the append writes an op, and the writer's stated
    /// intent is gone with nothing red anywhere. That is must #1 failing on an
    /// append path.
    ///
    /// When an op log DOES exist the same load ignores the file entirely (ADR
    /// 0019: the op log is authoritative and the `.md` is derived output the
    /// next render rewrites), so refusing there would block the writer over a
    /// file Maugham does not read as truth — a rule with a false reason, which
    /// this codebase treats as worse than no rule. `OpLogStore.opLogFileURLs`
    /// is asked here because it is the same predicate `Document.load` branches
    /// on; a guess of our own could disagree with it.
    ///
    /// A statement whose file is simply ABSENT is legitimately empty — a
    /// freshly minted one is zero bytes by design — so absence is not a
    /// refusal. `PromotionPerformer.readBody` draws the same line for the same
    /// reason.
    private static func refuseIfTheWordsCannotBeRead(
        _ statement: Statement, in store: ProjectStore
    ) throws {
        guard OpLogStore.opLogFileURLs(forDocId: statement.id, in: store.url).isEmpty
        else { return }
        let url = store.url.appendingPathComponent(statement.path)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        guard (try? String(contentsOf: url, encoding: .utf8)) != nil else {  // adr-0018-ok: a reachability probe on a statement's BOOTSTRAP bytes, guarded above on there being no op log — the exact read `Document.load` makes in that case, asked here so an undecodable file is a refusal rather than a silent empty
            throw IntentAppendFailure.unreadableDestination(statement.path)
        }
    }

    /// Session id for the ops an answer writes when no pane has the statement
    /// open. Stable for the launch, like every other session stamp
    /// (`PromotionPerformer.promotionSession`).
    private static let session = "compiler-answer-\(UUID().uuidString)"
}
