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
    @State private var practice: ProjectPractice?
    @State private var loadError: String?
    /// Hosting window (this is its own scene) for the ADR 0021 project scope +
    /// closed-window liveness guard — a closed stats window's zombie no longer
    /// reloads on a session-log change.
    @State private var window: NSWindow?

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
            // Closed documents, off their op logs (P3 constraint 30) — this
            // window runs its own stores, so the walk consults no live
            // `Document` and cannot disagree with what is on disk.
            self.practice = ProjectPractice.derive(
                store: s, projectURL: projectURL, now: Date())
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
        practice = ProjectPractice.derive(
            store: store, projectURL: projectURL, now: Date())
    }
}
