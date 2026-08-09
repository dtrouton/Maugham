import Foundation
@testable import Maugham

enum CandidateMover {
    /// Move user-editable content from `oldPath` to `newPath` (both
    /// project-relative, e.g. "research/note.md").
    ///
    /// Two writers can put bytes at the *old* path after the move has happened,
    /// and both have to be silenced first:
    ///
    ///   * the store's debounced research-note save, which targets the path it
    ///     was handed at schedule time (S-B-04, S-B-05); and
    ///   * an open `Document`, which autosaves on its own 750ms debounce to the
    ///     URL it captured when it was loaded (S-B-08) — a URL nothing in this
    ///     API can retarget.
    ///
    /// So the order is: quiesce every writer, *then* make the single coordinated
    /// filesystem mutation. That ordering is also what keeps S-B-16 cheap — only
    /// one step touches the filesystem, and it is atomic, so there is no
    /// half-moved state to roll back.
    @MainActor
    static func move(from oldPath: String, to newPath: String,
                     in store: DocumentStore) async throws {
        guard oldPath != newPath else { return }

        let sourceURL = store.projectURL.appendingPathComponent(oldPath)
        let destinationURL = store.projectURL.appendingPathComponent(newPath)

        // 1. Flush the store's debounced save *before* the move. A pending write
        //    is aimed at whatever path it was scheduled with (S-B-05); if it were
        //    still pending when the move landed it would recreate the source file
        //    ~750ms later. Flushing now lands the writer's latest text at the old
        //    path, which is exactly the content the move then carries across.
        //    No-op when nothing is pending (S-B-07).
        try await store.flushPendingSave()

        // 2. Close and unregister any open Document at either end. `close()`
        //    cancels its timers and flushes pending state first (S-B-09), so the
        //    file on disk is current before we touch it; `unregister` then drops
        //    the stale path mapping (S-B-11). The destination is quiesced for the
        //    same reason: a live Document there would autosave its own text over
        //    the bytes we just moved in, breaking S-B-14.
        await closeAndUnregisterDocument(at: oldPath, in: store)
        await closeAndUnregisterDocument(at: newPath, in: store)

        // 3. The only filesystem mutation, coordinated so the app's file
        //    presenter is notified (S-B-01, S-B-15). It throws if the source is
        //    missing or the destination cannot be replaced (S-B-02); nothing has
        //    been mutated at that point, so there is nothing to unwind (S-B-16).
        //    The bytes are moved, never rewritten (S-B-14), and the call is blind
        //    to whether the file is a manuscript or a research note (S-B-17).
        try await store.coordinatedMove(from: sourceURL, to: destinationURL)
    }

    @MainActor
    private static func closeAndUnregisterDocument(at path: String,
                                                  in store: DocumentStore) async {
        guard let document = store.document(for: path) else { return }
        await document.close()
        store.unregister(path: path)
    }
}
