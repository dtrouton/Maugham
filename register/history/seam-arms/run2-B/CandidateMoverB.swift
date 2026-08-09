import Foundation
@testable import Maugham

enum CandidateMover {
    /// Move user-editable content from `oldPath` to `newPath` (both
    /// project-relative, e.g. "research/note.md").
    ///
    /// The order below is the whole of the design. Two independent writers can
    /// re-create the file at `oldPath` *after* the bytes have moved:
    ///
    ///   * an open `Document`, which autosaves on its own 750ms debounce to the
    ///     URL it captured at load time (S-B-08) and can therefore never learn
    ///     about the new path; and
    ///   * the store's own debounced save, which targets the path supplied at
    ///     schedule time (S-B-05).
    ///
    /// Both are silenced *before* the move, while `oldPath` is still the
    /// correct destination for anything they had buffered, so no keystroke is
    /// dropped and nothing is left behind.
    @MainActor
    static func move(from oldPath: String, to newPath: String,
                     in store: DocumentStore) async throws {
        guard oldPath != newPath else { return }

        let sourceURL = store.projectURL.appendingPathComponent(oldPath)
        let destinationURL = store.projectURL.appendingPathComponent(newPath)

        // 1. Quiesce the open Document at this path, if there is one. `close()`
        //    cancels its timers and flushes any pending state (S-B-09) — which
        //    lands on the old URL, correctly, because the bytes have not moved
        //    yet. Then drop it from the registry: it is no longer usable, and
        //    re-registering it at `newPath` would only re-arm a writer aimed at
        //    the old URL.
        if let document = store.document(for: oldPath) {
            await document.close()
            store.unregister(path: oldPath)
        }

        // 2. Same hazard on the store's side, for content that is not an open
        //    Document (research notes). Let any debounced write land now.
        //    No-op when nothing is pending (S-B-07).
        try await store.flushPendingSave()

        // 3. The move itself: a single coordinated step (S-B-01, S-B-15), so
        //    there is no window in which the content exists at neither path,
        //    and no partial state to unwind if it throws (S-B-16).
        try await store.coordinatedMove(from: sourceURL, to: destinationURL)
    }
}
