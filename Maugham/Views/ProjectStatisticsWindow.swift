import SwiftUI
import AppKit

struct ProjectStatisticsWindow: View {
    let projectURL: URL
    /// The project's session, BORROWED as a reader (foundations plan 3,
    /// Task 4) — never opened here. See `ProjectStatisticsSource`.
    @State private var source = ProjectStatisticsSource()
    @Environment(ProjectSessionRegistry.self) private var sessions
    private var store: ProjectStore? { source.store }
    @State private var sessionLog: SessionLog = .empty
    /// The Practice section's whole input (editorial letter P3, spec §5
    /// surface 1). `nil` until the walk has run once, which is what lets the
    /// section say it is still reading rather than that there is nothing to
    /// read.
    ///
    /// **That placeholder is the real first frame** (ruling R18). The walk runs
    /// on a detached task, so the window draws its four counted sections as
    /// soon as the stores are open and the Practice section sits on
    /// `PracticeSection.derivingTitle` until the op logs have been read — which
    /// on a 30-chapter book is over a second.
    @State private var practice: ProjectPractice?
    @State private var loadError: String?
    /// Hosting window (this is its own scene) for the ADR 0021 project scope +
    /// closed-window liveness guard — a closed stats window's zombie no longer
    /// reloads on a session-log change.
    @State private var window: NSWindow?
    /// The walk in flight, held so the NEXT one can cancel it.
    ///
    /// The walk is seconds long on a real book and a session can end while one
    /// is running, so two can overlap — and the one that finishes last is not
    /// the one that started last. Cancelling means the older task drops its
    /// result instead of writing a stale `practice` over a newer one; the
    /// detached work itself is left to finish, since it holds no lock and
    /// nothing waits on it.
    @State private var deriveTask: Task<Void, Never>?

    var body: some View {
        Group {
            if let store {
                ProjectStatisticsView(
                    store: store,
                    sessionLog: sessionLog,
                    practice: practice,
                    onSelectChapter: { id in
                        // Project-scoped (ADR 0021): un-breaks stats-window
                        // navigation. The old key-window receiver guard could
                        // never pass while the (separate) stats window was key.
                        MaughamEvent.post(
                            .maughamNavigateToDocument,
                            to: .project(for: projectURL),
                            payload: ["id": id])
                    })
            } else if let loadError {
                VStack {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text("Couldn't load statistics").font(.headline)
                    Text(loadError).foregroundStyle(.secondary)
                }
                .padding(48)
            } else {
                ProgressView("Loading…")
            }
        }
        .frame(minWidth: 720, minHeight: 600)
        .background(WindowAccessor(window: $window))
        .navigationTitle(store?.manifest.title ?? "Statistics")
        .task(id: projectURL) { await load() }
        .onProjectEvent(.maughamSessionLogChanged, url: projectURL, window: window) { _ in
            Task { await reloadSessionLog() }
        }
        .onDisappear {
            // `ProjectWindow`'s guard, for its reason: a spurious
            // `.onDisappear` on a still-live window must keep the borrow, or
            // the window sits on its stores' absence for good (`.task(id:)`
            // will not re-fire for the same url). Taken synchronously, so a
            // later `.onDisappear` or `load()` cannot give it back twice.
            if !MaughamEvent.isLive(window), let lease = source.relinquish() {
                let sessions = self.sessions
                Task { await sessions.release(lease) }
            }
        }
    }

    private func load() async {
        do {
            guard let s = try await source.load(projectURL, from: sessions, keep: {
                // `ProjectWindow.load()`'s keep-check: a cancelled load on a
                // window already known closed hands its borrow back — its
                // `.onDisappear` saw no lease and released nothing. The LIVE
                // `self.window`, read here after the acquire and never
                // snapshotted before it: `WindowAccessor` fills it on a later
                // main-queue turn, so a copy taken when the task starts is
                // routinely nil and would keep every borrow.
                ProjectStatisticsSource.keepsBorrow(
                    cancelled: Task.isCancelled, window: self.window)
            }) else { return }
            self.sessionLog = await source.loadSessionLog() ?? .empty
            rederivePractice(store: s)
        } catch {
            self.loadError = error.localizedDescription
        }
    }

    /// **The same trigger for both**, because a session ending is exactly when
    /// a process number changed: the frontier moved, a paragraph was rewritten
    /// again, or the count of sessions since either grew by one.
    private func reloadSessionLog() async {
        guard let store, let log = await source.loadSessionLog() else { return }
        sessionLog = log
        rederivePractice(store: store)
    }

    /// **The walk, off the main actor** — the one production caller of
    /// `ProjectPractice.derive(plan:projectURL:now:)`.
    ///
    /// Closed documents, off their op logs (P3 constraint 30): the walk reads
    /// only the manifest plan and the files on disk, never a live `Document`
    /// in the borrowed session, so it cannot disagree with what is on disk. It also reads every op log in the
    /// project, which measured 1.3–1.9 s on a 30-chapter book — run inline it
    /// froze the whole app on window open and again on every session end while
    /// the window was up. So only the manifest read (`ProjectPractice.Plan`)
    /// happens here; the reading happens detached, and the result comes back to
    /// the main actor to be assigned.
    private func rederivePractice(store: ProjectStore) {
        deriveTask?.cancel()
        let plan = ProjectPractice.Plan(store: store)
        let url = projectURL
        deriveTask = Task {
            let derived = await Task.detached(priority: .userInitiated) {
                ProjectPractice.derive(plan: plan, projectURL: url, now: Date())
            }.value
            guard !Task.isCancelled else { return }
            practice = derived
        }
    }
}

/// **The Statistics window's data source: the project's session, borrowed as
/// a READER** (foundations plan 3, Task 4).
///
/// The window used to open a `DocumentStore` of its own and hold it only
/// through `ProjectStore.documentStore`, which is `weak` — so the store was
/// released at once, every session-log reload returned early, and opening
/// Statistics repeated the open-time registry acts (the register declaration,
/// the seal/rotate sweep, a second file presenter). Now it asks
/// `ProjectSessionRegistry` for the project's session: a window's live one is
/// borrowed, opening nothing; with none open, the registry opens one and this
/// window's release closes it. A READER borrow holds only the stores: it never
/// attaches a window, configures a service or registers with MCP, so the last
/// project window closing still detaches every `claude` service while
/// Statistics stays up.
///
/// A plain `@MainActor` model so the borrow is pinned without a window
/// (`ProjectStatisticsWindowSessionTests`).
@MainActor @Observable
final class ProjectStatisticsSource {
    /// The one borrow this window holds, owed one release.
    private(set) var lease: ProjectSessionRegistry.Lease?

    var store: ProjectStore? { lease?.session.projectStore }

    /// Borrows the session for `url` as a reader and answers its store, or
    /// nil if the borrow went straight back. A re-run while a borrow is held
    /// acquires nothing. `keep` is asked after the acquire with no suspension
    /// point before the adoption: a borrow this window will not keep is
    /// released, never left with nobody to give it back.
    func load(_ url: URL, from sessions: ProjectSessionRegistry,
              keep: () -> Bool = { true }) async throws -> ProjectStore? {
        if let lease { return lease.session.projectStore }
        let acquired = try await sessions.acquire(url, as: .reader) {
            try await ProjectSession.open(url: url)
        }
        if lease != nil || !keep() {
            await sessions.release(acquired)
            return lease?.session.projectStore
        }
        lease = acquired
        return acquired.session.projectStore
    }

    /// The session log, read off the borrowed session's LIVE `DocumentStore`;
    /// nil while nothing is borrowed.
    func loadSessionLog() async -> SessionLog? {
        guard let documentStore = lease?.session.documentStore else { return nil }
        return (try? await documentStore.loadSessionLog()) ?? .empty
    }

    /// Whether a load keeps the borrow it just acquired — `ProjectWindow.load()`'s
    /// rule: hand it back only when the load was cancelled AND the window is
    /// known gone. A cancelled load on a live window (or one not yet known)
    /// keeps it, since nothing promises the task re-runs.
    static func keepsBorrow(cancelled: Bool, window: NSWindow?) -> Bool {
        !(cancelled && window != nil && !MaughamEvent.isLive(window))
    }

    /// Hands the borrow over to be released and forgets it, synchronously.
    func relinquish() -> ProjectSessionRegistry.Lease? {
        defer { lease = nil }
        return lease
    }
}
