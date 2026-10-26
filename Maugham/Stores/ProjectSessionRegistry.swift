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
///
/// **Two kinds of borrow** (Task 3b). A `.window` borrow ATTACHES its window
/// (`ProjectSession.attachWindow` — the canvas seam, the flash, the services),
/// and the newest window wins; giving it back detaches it
/// (`ProjectSession.detachWindow`), handing the attachment to the newest
/// window still open, or — if none is — detaching every service, so no warm
/// `claude` session outlives the last window on a project. MCP registration
/// follows the window borrows too: registered while one is out, unregistered
/// when the last goes back. A `.reader` borrow holds only the stores. The
/// LAST borrow of either kind closes the session.
@MainActor @Observable
final class ProjectSessionRegistry {
    /// What a borrower is to the session.
    enum Borrow {
        /// A project window: `attach` attaches it to the session (in
        /// production, `ProjectSession.attachWindow` with the window's canvas
        /// and flash) and answers the attachment. Kept for the life of the
        /// borrow, because when a newer window goes back first the attachment
        /// returns to this one. `isLive` answers whether the window is still
        /// open: a borrow that leaked (its window gone, its release never
        /// made) must never be handed the attachment back — that would make
        /// a closed window's canvas the live one and keep the services warm
        /// for nobody. A window not yet known (no `NSWindow` in hand) answers
        /// live, so a window still appearing is never dropped.
        case window(attach: @MainActor (ProjectSession) -> ProjectSession.WindowAttachment,
                    isLive: @MainActor () -> Bool)
        /// Anything that only reads the stores (the Statistics window).
        case reader
    }

    /// One borrow, owed one `release`. Releasing it twice is a no-op.
    struct Lease {
        let session: ProjectSession
        fileprivate let key: String
        fileprivate let serial: Int
    }

    private struct WindowBorrow {
        let serial: Int
        let attach: @MainActor (ProjectSession) -> ProjectSession.WindowAttachment
        let isLive: @MainActor () -> Bool
        var attachment: ProjectSession.WindowAttachment
    }

    private struct Entry {
        let session: ProjectSession
        /// Oldest first; the LAST is the attached window.
        var windows: [WindowBorrow] = []
        var readers: Set<Int> = []
        var isEmpty: Bool { windows.isEmpty && readers.isEmpty }
    }

    /// Keyed by `key(for:)`, never by a raw URL.
    private var entries: [String: Entry] = [:]
    @ObservationIgnored private var opening: [String: Task<ProjectSession, Error>] = [:]
    @ObservationIgnored private var closing: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var borrowSerial = 0
    /// Where a project with a window open is announced to MCP. `nil` in a
    /// test that does not care.
    @ObservationIgnored private let mcp: ProjectRegistry?

    init(mcp: ProjectRegistry? = nil) {
        self.mcp = mcp
    }

    /// Test seam: how many sessions are open.
    var openCount: Int { entries.count }

    /// The one spelling of a project's identity here: standardised, symlinks
    /// resolved, and compared as a PATH, so `Book` and `Book/` (which `URL`
    /// equality tells apart) are one project.
    static func key(for url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    /// The open session for `url` WITHOUT borrowing it, or nil — a figure
    /// window's lookup: it closes with its project and holds nothing open.
    func session(for url: URL) -> ProjectSession? {
        entries[Self.key(for: url)]?.session
    }

    /// The open session for `url`, opening it through `open` if there is none
    /// — concurrent callers for one URL await the SAME open, never two — and
    /// borrowed `as` a window (attached, newest wins) or a reader. Each
    /// successful return is one borrow, owed one `release`.
    func acquire(
        _ url: URL,
        as borrow: Borrow,
        open: @escaping @MainActor () async throws -> ProjectSession
    ) async throws -> Lease {
        let key = Self.key(for: url)
        while true {
            if let close = closing[key] {
                await close.value
                // Cleared here as well as by the release that started it:
                // awaiting a FINISHED task need not suspend, so until the
                // release has resumed to clear it this loop would find the
                // same finished close forever, holding the main actor the
                // release needs in order to resume (measured: a hang).
                if closing[key] == close { closing[key] = nil }
                continue   // the world changed while we waited; look again
            }
            if var entry = entries[key] {
                borrowSerial += 1
                let serial = borrowSerial
                switch borrow {
                case .reader:
                    entry.readers.insert(serial)
                case .window(let attach, let isLive):
                    if entry.windows.isEmpty {
                        mcp?.register(url: entry.session.url, store: entry.session.projectStore)
                    }
                    entry.windows.append(WindowBorrow(
                        serial: serial, attach: attach, isLive: isLive,
                        attachment: attach(entry.session)))
                }
                entries[key] = entry
                return Lease(session: entry.session, key: key, serial: serial)
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
                entries[key] = Entry(session: session)
            }
        }
    }

    /// Gives one borrow back. A window's release detaches it
    /// (`ProjectSession.detachWindow`): if it was the attached window, the
    /// NEWEST older borrow whose window is still live is attached again
    /// first, so the detach finds a newer attachment and changes nothing —
    /// and every newer borrow whose window is gone is dropped on the way,
    /// never reattached (a leaked borrow must not revive a closed window).
    /// If no live window is left, every service detaches and MCP forgets the
    /// project. The
    /// last release of ANY kind closes the session (`ProjectSession.close()`
    /// — the roster detaches, then the DocumentStore drains) and returns once
    /// that close has finished. A lease already given back does nothing.
    func release(_ lease: Lease) async {
        let key = lease.key
        guard var entry = entries[key], entry.session === lease.session else { return }
        let session = entry.session
        if let index = entry.windows.firstIndex(where: { $0.serial == lease.serial }) {
            let leaving = entry.windows.remove(at: index)
            if session.attachment == leaving.attachment {
                // Newest first; a dead borrow is dropped. Its attachment is
                // already stale (the leaving window's was the live one), so
                // nothing needs detaching for it, and its own late release,
                // if it ever comes, finds no borrow and does nothing.
                while var newest = entry.windows.popLast() {
                    guard newest.isLive() else { continue }
                    newest.attachment = newest.attach(session)
                    entry.windows.append(newest)
                    break
                }
            }
            session.detachWindow(leaving.attachment)
            if entry.windows.isEmpty {
                mcp?.unregister(url: session.url)
            }
        } else if entry.readers.remove(lease.serial) == nil {
            return
        }
        guard entry.isEmpty else {
            entries[key] = entry
            return
        }
        entries[key] = nil
        let close = Task { @MainActor in await session.close() }
        closing[key] = close
        await close.value
        if closing[key] == close { closing[key] = nil }
    }

    /// App quit: ends every warm `claude` session of every open project —
    /// `AgentRoster.shutdownAll()` on each session's roster — whether or not
    /// a live window still holds it. The windows' own quit arms reach only
    /// the rosters a mounted window holds; a session a reader (or a leaked
    /// borrow) kept open would otherwise outlive the app as a billing
    /// process. Synchronous, because `willTerminate` gives nothing time to
    /// await. Borrows and stores are left alone: the process is ending.
    func shutdownAll() {
        for entry in entries.values {
            entry.session.roster.shutdownAll()
        }
    }
}
