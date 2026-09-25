import Foundation
import MaughamCore

/// **A piece this device may not write, opened before it has arrived**
/// (signed op log P3a Task 8, spec §4.6).
///
/// `Document.load` runs `Bootstrap` on a document with no op log, because the
/// ordinary meaning of *no history* is *a new or imported file whose `.md` is
/// the seed*. On a Mac whose writer is a reviewer, or an author of some pieces
/// and this is not one of them, that meaning is wrong: the far likelier reading
/// is *this piece's ops have not synced yet*, and minting a `bootstrap` would
/// put a line in the book that the permit partition sets aside on the next read
/// — a document whose opening op leaves the book derives EMPTY, and the first
/// autosave writes the empty render over the manuscript.
///
/// So the load refuses, and it refuses in a word of its own. It is an `Error`
/// because that is the channel `EditorHost.loadDocumentIfNeeded` already has
/// and a second one would be the parallel state tripwire 6 is about — but it is
/// not a failure, and nothing on the way to the writer treats it as one: no
/// notice is posted, no recovery ladder is offered, and the pane says what is
/// happening rather than what went wrong.
///
/// **It reads nothing from the `.md`** (tripwire 20). There is no truth there
/// to show: the file on disk is a derived render of a history this device has
/// not got.
public enum DocumentLoadError: Error, Equatable {
    /// This device may not write this piece, and the piece has no history here
    /// yet. `root` is the label of the root that would add it, where the
    /// registry names one.
    case waitingForPiece(docId: String, from: String?)
}

extension DocumentLoadError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .waitingForPiece(_, let root):
            if let root {
                return "Waiting for this piece to arrive from \(root)."
            }
            return "Waiting for this piece to arrive."
        }
    }
}

extension Document {

    /// **Where a stream sits, for the permit check** (spec §4.1).
    ///
    /// Reached only where the permit is narrow enough for the answer to turn on
    /// it (`OpLogStore.localWritePermit` calls this as a closure), so a book
    /// with no permit events never decodes a manifest for it.
    ///
    /// **A manifest that will not read must never make a load refuse that did
    /// not refuse before.** `try?` throughout: a nil manifest is no statements,
    /// and no statements resolves every id to `.piece(docId)`, which is the
    /// WIDENING direction — a piece is the class an author-of-some-pieces can
    /// actually hold, where `.projectStatement` would refuse her. The load is
    /// not the right place to discover a broken manifest; `ProjectStore.load`
    /// is, and it says so in its own words.
    ///
    /// **One spelling** (P3a Task 5): the rule above is
    /// `OpLogStore.documentClass(forDocId:in:)`'s, because the permit PARTITION
    /// asks the same question of the same file on the read side and two answers
    /// about where a stream sits is two answers about who may write it.
    internal static func documentClass(
        forDocId docId: String, in projectURL: URL
    ) -> DocumentClass {
        OpLogStore.documentClass(forDocId: docId, in: projectURL)
    }

    /// **The sentence the PANE shows, which knows one thing the error does
    /// not** (P3b Task 7, spec §4.5's other half).
    ///
    /// `DocumentLoadError.waitingForPiece` says *waiting for this piece to
    /// arrive*, which is the whole truth on a REVIEWER's Mac: she may write no
    /// piece of this book, so no piece is ever going to become hers and what
    /// she is waiting for is the ops. On the Mac of somebody who may write
    /// SOME of it, that sentence is misleading in the direction that matters —
    /// she is not waiting for a file, she is waiting for a person, and the
    /// thing that would end the wait is the root saying this piece is hers.
    ///
    /// **Why the error keeps its own words.** It is a generic channel: MCP
    /// returns it over a socket, a log records it, and neither knows whether
    /// anybody is looking. The PANE is the one place that knows the writer is
    /// reading the sentence right now, so it is the one place worth spending a
    /// registry read on to make it exact. `EditorHost` asks; nothing else does.
    ///
    /// **It reads nothing from the `.md`** (tripwire 20) and it asks the
    /// PERMIT LAYER rather than comparing a rung (tripwire 47):
    /// `Permit.mayStartAPieceOfTheirOwn` is the question *may this person open
    /// a piece of their own at all*, and it is spelled once, there.
    ///
    /// Only ever called on the refusing path, which is what licenses a second
    /// registry read — the ordinary load has gone past this point and paid
    /// nothing.
    @MainActor
    internal static func waitingSentence(
        _ error: DocumentLoadError, docId: String, in projectURL: URL
    ) -> String {
        guard case .waitingForPiece(_, let root) = error else {
            return error.localizedDescription
        }
        let opStore = OpLogStore(
            projectURL: projectURL, identities: loadIdentities,
            state: loadDeviceState, cache: loadRegistryCache)
        let permit = opStore.localWritePermit {
            Document.documentClass(forDocId: docId, in: projectURL)
        }
        guard permit.permit.mayStartAPieceOfTheirOwn else {
            return error.localizedDescription
        }
        // **A piece she may already write is waiting for its OPS, not for a
        // person** (P3c plan 2, Option A). Since every creation records its
        // starter, a narrowed book's piece is minted by that Mac alone — so
        // her OWN piece started on another Mac, and a piece she started on her
        // other Mac, wait here until the opening arrives. Nobody is deciding
        // anything about either, so the sentence names no root.
        if permit.permit.namesPiece(docId) || permit.writesAsItsStarter {
            return DocumentLoadError.waitingForPiece(docId: docId, from: nil)
                .localizedDescription
        }
        return Self.waitingToBeToldItIsYours(root: root)
    }

    /// **Denver's words for a piece that is not hers yet** (P3c plan 2,
    /// Option A): the pane's waiting sentence and her standing line over a
    /// piece she started and nobody has claimed say the same thing, so they
    /// are spelled once. `root` nil names the root by what it is.
    nonisolated static func waitingToBeToldItIsYours(root: String?) -> String {
        "Waiting for \(root ?? "the book\u{2019}s author") to say this piece is yours."
    }

    /// The label of the root this device is on, for the waiting sentence — or
    /// nil, which is the sentence without its last clause.
    ///
    /// **Only ever called on the refusing path**, which is why it is allowed to
    /// read the registry a second time: the ordinary load has already gone past
    /// this point and paid nothing.
    internal static func rootLabelForWaiting(in projectURL: URL) -> String? {
        rootLabel(in: projectURL, identities: loadIdentities, cache: loadRegistryCache)
    }

    /// `rootLabelForWaiting`'s body, callable OFF the main actor — the
    /// standing line reads the same label from a detached task
    /// (`PostureStandingLine.rootLabel`), so the two cannot name two roots.
    ///
    /// **Nil on a root's own Mac** (P3c plan 2, OA-2). The root waits too now,
    /// for a piece somebody else started; *waiting for this piece to arrive
    /// from Denver* on Denver's own Mac names the one person who is certainly
    /// not what the wait is for. `Registry.holdsARootRecord` is the one test of
    /// who is a root (Ruling AA).
    nonisolated static func rootLabel(
        in projectURL: URL, identities: LocalIdentities, cache: RegistryCache
    ) -> String? {
        guard let registry = try? TrustResolution.verifiedRegistry(
            projectURL: projectURL, cache: cache) else { return nil }
        guard !registry.holdsARootRecord(identities.author.fingerprint) else {
            return nil
        }
        let table = TrustTable.resolve(
            registry: registry, mine: identities,
            joinedRoot: cache.joinedRoot(for: projectURL))
        guard let root = table.myRoot else { return nil }
        return registry.roots.first { $0.person == root }?.label
    }
}
