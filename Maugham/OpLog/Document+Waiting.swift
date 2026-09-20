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

    /// The label of the root this device is on, for the waiting sentence — or
    /// nil, which is the sentence without its last clause.
    ///
    /// **Only ever called on the refusing path**, which is why it is allowed to
    /// read the registry a second time: the ordinary load has already gone past
    /// this point and paid nothing.
    internal static func rootLabelForWaiting(in projectURL: URL) -> String? {
        guard let registry = try? TrustResolution.verifiedRegistry(
            projectURL: projectURL, cache: loadRegistryCache) else { return nil }
        let table = TrustTable.resolve(
            registry: registry, mine: loadIdentities,
            joinedRoot: loadRegistryCache.joinedRoot(for: projectURL))
        guard let root = table.myRoot else { return nil }
        return registry.roots.first { $0.person == root }?.label
    }
}
