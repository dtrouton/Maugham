import Foundation
import os

/// Moves user-editable content (a manuscript `.md`/`.fountain`, or a research
/// note) from one project-relative path to another.
///
/// The hard part is not the filesystem call — it is the two debounced autosave
/// timers that both captured a *path* when they were scheduled (S-B-05, S-B-08).
/// Either one firing after the file has moved writes the file back into
/// existence at the path it no longer occupies (S-S-01). So the whole of the
/// close-and-flush discipline (S-S-02) runs to completion *before* the first
/// filesystem call of the move, and it lives here rather than at the call
/// sites, so no caller can forget half of it (S-S-07).
enum CandidateMover {

    private static let log = Logger(subsystem: "com.maugham.experiment",
                                    category: "CandidateMover")

    /// Move user-editable content from `oldPath` to `newPath` (both
    /// project-relative, e.g. "research/note.md").
    @MainActor
    static func move(from oldPath: String, to newPath: String,
                     in store: DocumentStore) async throws {
        let source = normalize(oldPath)
        let destination = normalize(newPath)

        // Moving a path onto itself is a no-op, not an error: `coordinatedMove`
        // would be asked to replace a file with itself (S-B-02).
        guard source != destination else { return }

        // --- S-S-02 (i): close and unregister, before any filesystem call. ---
        //
        // Closing alone leaves the registry resolving a path that no longer
        // exists; unregistering alone leaves the Document's own 750ms timer
        // live and pointed at the URL it captured at load time (S-S-04). Both
        // halves, in that order — close first so the document's pending state
        // is flushed to the file while the file is still at `source`, and only
        // then drop it from the registry.
        //
        // The destination path is handled the same way: a Document open there
        // is about to have its file replaced underneath it, and its captured
        // URL would make it rewrite the file we just moved into place.
        for path in [source, destination] {
            guard let document = store.document(for: path) else { continue }
            await document.close()
            store.unregister(path: path)
        }

        // --- S-S-02 (ii): drain the research-note debounce. ---
        //
        // One call, not one per path: the scheduler is drained whole (S-S-03),
        // which covers a pending write to any note underneath a moved folder as
        // well as to the moved path itself.
        //
        // A flush failure must not abort the move — the surgery still has to
        // happen — but it must not vanish either, so that a last edit lost on
        // the way into a move leaves a trace (S-S-05).
        do {
            try await store.flushPendingSave()
        } catch {
            log.error("""
                Pending save flush failed before moving \(source, privacy: .public) \
                to \(destination, privacy: .public); the last edit to a pending \
                research note may be lost. Proceeding with the move. \
                Error: \(error.localizedDescription, privacy: .public)
                """)
        }

        // --- The move itself. ---
        //
        // Exactly one filesystem mutation, through the coordinator, so the
        // app's own file presenter is notified (S-B-15) and the bytes are
        // carried across untouched — no read-and-rewrite (S-B-14). One
        // operation is also what keeps a throw from leaving a half-moved
        // project (S-B-16): either the item is at `source` or it is at
        // `destination`.
        //
        // Nothing is re-registered afterwards. Any Document that was open here
        // is closed, and a closed Document is not this function's to reopen;
        // the caller reopens at the new path if it still wants it.
        try await store.coordinatedMove(
            from: store.projectURL.appending(path: source),
            to: store.projectURL.appending(path: destination)
        )
    }

    /// Strip leading slashes so a project-relative path cannot be mistaken for
    /// an absolute one when it is appended to `projectURL` (S-B-13), and drop a
    /// trailing slash so a folder path compares equal to itself.
    private static func normalize(_ path: String) -> String {
        var trimmed = path
        while trimmed.hasPrefix("/") { trimmed.removeFirst() }
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        return trimmed
    }
}
