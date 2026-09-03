import SwiftUI
import AppKit

struct ProjectStatisticsWindow: View {
    let projectURL: URL
    @State private var store: ProjectStore?
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
    }

    private func load() async {
        do {
            let s = try await ProjectStore.load(from: projectURL)
            let ds = try await DocumentStore.open(url: projectURL)
            s.documentStore = ds
            self.store = s
            self.sessionLog = (try? await ds.loadSessionLog()) ?? .empty
            rederivePractice(store: s)
        } catch {
            self.loadError = error.localizedDescription
        }
    }

    /// **The same trigger for both**, because a session ending is exactly when
    /// a process number changed: the frontier moved, a paragraph was rewritten
    /// again, or the count of sessions since either grew by one.
    private func reloadSessionLog() async {
        guard let store, let documentStore = store.documentStore else { return }
        sessionLog = (try? await documentStore.loadSessionLog()) ?? .empty
        rederivePractice(store: store)
    }

    /// **The walk, off the main actor** — the one production caller of
    /// `ProjectPractice.derive(plan:projectURL:now:)`.
    ///
    /// Closed documents, off their op logs (P3 constraint 30): this window runs
    /// its own stores, so the walk consults no live `Document` and cannot
    /// disagree with what is on disk. It also reads every op log in the
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
