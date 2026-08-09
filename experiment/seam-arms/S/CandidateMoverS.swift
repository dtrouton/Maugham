import Foundation
import os

@testable import Maugham

enum CandidateMover {

    private static let log = Logger(subsystem: "com.maugham.experiment",
                                    category: "CandidateMover")

    /// Move user-editable content from `oldPath` to `newPath` (both
    /// project-relative, e.g. "research/note.md").
    ///
    /// Three parties race here: this mover, the open `Document`'s own 750ms
    /// autosave (S-B-08), and the store's 750ms research-note debounce
    /// (S-B-04). Both timers capture their target path at schedule time
    /// (S-B-05, S-B-08), so either one firing after the filesystem move
    /// re-creates a phantom file at the old path (S-S-01). Hence: quiesce both,
    /// for every path this move touches, *before* any filesystem call (S-S-02).
    @MainActor
    static func move(from oldPath: String, to newPath: String,
                     in store: DocumentStore) async throws {

        // A move onto itself has nothing to quiesce and nothing to move; doing
        // the surgery anyway would ask the coordinator to replace a file with
        // itself. Bail before taking any side effect.
        guard oldPath != newPath else { return }

        // 1. Quiesce every open Document on a path this move affects.
        //
        //    The source, obviously. The destination too: a Document open there
        //    captured the destination URL at load time, so leaving it live
        //    would let it autosave its now-superseded text straight back over
        //    the bytes we are about to move in.
        //
        //    Closing and unregistering are both required and neither implies
        //    the other (S-S-04): close alone leaves the registry resolving a
        //    path that no longer holds that file; unregister alone leaves a
        //    live timer that still fires at the old URL.
        for path in [oldPath, newPath] {
            guard let document = store.document(for: path) else { continue }
            await document.close()          // cancels timers, flushes (S-B-09)
            store.unregister(path: path)    // registry stops resolving (S-B-11)
        }

        // 2. Drain the store's research-note debounce. One call covers every
        //    pending write in the scheduler, not just this path (S-S-03).
        //
        //    A flush failure means a research note lost its last edit, which is
        //    bad — but it is not a reason to abandon the move and leave the
        //    caller's rename half-done. Proceed, and leave a trace rather than
        //    swallowing it (S-S-05).
        do {
            try await store.flushPendingSave()
        } catch {
            log.error("""
                Pending research-note save failed to flush before moving \
                \(oldPath, privacy: .public) -> \(newPath, privacy: .public); \
                the last edit to a note may be lost. Proceeding with the move. \
                Error: \(String(describing: error), privacy: .public)
                """)
        }

        // 3. Only now touch the filesystem, and touch it exactly once, through
        //    the coordinator so the app's own file presenter is notified
        //    (S-B-15). A single coordinated move is also what keeps a failure
        //    from leaving a half-moved project (S-B-16) and what leaves
        //    the bytes untouched (S-B-14) — we never read or rewrite content,
        //    so a manuscript and a research note go through identically
        //    (S-B-17).
        let sourceURL = store.projectURL.appendingPathComponent(oldPath)
        let destinationURL = store.projectURL.appendingPathComponent(newPath)
        try await store.coordinatedMove(from: sourceURL, to: destinationURL)
    }
}
