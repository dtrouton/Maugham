import Foundation
import Observation

/// **One `ProjectSession` per project, borrowed by every window on it**
/// (foundations plan 3, Task 3).
///
/// `ProjectSession.open` is not idempotent: `DocumentStore.open` declares this
/// Mac in the register, runs recognition, sweeps and rotates seals (rotation
/// DELETES) and starts transcription, and installs a file presenter. Two
/// windows on one project each running it would put two presenters and two
/// open-time sweeps on one folder. So the app holds this one registry and a
/// window ASKS it for the project's session: the first `acquire` opens it,
/// every later one borrows the same object, and the last `release` closes it.
///
/// The session carries its roster, so a second window on a project shares the
/// first one's warm `claude` services rather than starting its own.
///
/// Three rules make the count trustworthy:
/// - **one open in flight per project** — concurrent `acquire`s for one URL
///   all await the SAME unstructured `Task`, which a caller's cancellation
///   does not reach, so a window that goes away mid-open cannot fail the open
///   for the others;
/// - **a failed open registers nothing**, so the next `acquire` retries;
/// - **a close in flight is waited out** — an `acquire` arriving while the
///   last borrow's close is still running waits for it and then opens fresh,
///   never borrowing a session that is being torn down and never opening
///   alongside a close of the same folder.
@MainActor @Observable
final class ProjectSessionRegistry {
    private struct Entry {
        let session: ProjectSession
        var borrows: Int
    }

    /// Keyed by `key(for:)`, never by a raw URL.
    private var entries: [String: Entry] = [:]
    @ObservationIgnored private var opening: [String: Task<ProjectSession, Error>] = [:]
    @ObservationIgnored private var closing: [String: Task<Void, Never>] = [:]

    /// Test seam: how many sessions are open.
    var openCount: Int { entries.count }

    /// The one spelling of a project's identity here: standardised, symlinks
    /// resolved, and compared as a PATH, so `Book` and `Book/` (which `URL`
    /// equality tells apart) are one project.
    static func key(for url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    /// The open session for `url`, opening it through `open` if there is none
    /// — concurrent callers for one URL await the SAME open, never two. Each
    /// successful return is one borrow, owed one `release`.
    func acquire(
        _ url: URL,
        open: @escaping @MainActor () async throws -> ProjectSession
    ) async throws -> ProjectSession {
        let key = Self.key(for: url)
        while true {
            if let close = closing[key] {
                await close.value
                continue   // the world changed while we waited; look again
            }
            if var entry = entries[key] {
                entry.borrows += 1
                entries[key] = entry
                return entry.session
            }
            let task: Task<ProjectSession, Error>
            if let inFlight = opening[key] {
                task = inFlight
            } else {
                task = Task { @MainActor in try await open() }
                opening[key] = task
            }
            let session: ProjectSession
            do {
                session = try await task.value
            } catch {
                // Nothing registered: the next acquire opens afresh.
                if opening[key] == task { opening[key] = nil }
                throw error
            }
            // The first caller to resume installs the entry; the others find
            // it on the next turn of the loop and borrow it there.
            if opening[key] == task {
                opening[key] = nil
                entries[key] = Entry(session: session, borrows: 0)
            }
        }
    }

    /// Gives one borrow back; the last release for a URL closes the session
    /// (`ProjectSession.close()` — the roster detaches, then the
    /// DocumentStore drains) and returns once that close has finished. A
    /// release for a URL with no open session does nothing.
    func release(_ url: URL) async {
        let key = Self.key(for: url)
        guard var entry = entries[key] else { return }
        entry.borrows -= 1
        if entry.borrows > 0 {
            entries[key] = entry
            return
        }
        entries[key] = nil
        let session = entry.session
        let close = Task { @MainActor in await session.close() }
        closing[key] = close
        await close.value
        if closing[key] == close { closing[key] = nil }
    }
}
