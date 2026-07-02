import SwiftUI
import AppKit

struct ProjectStatisticsWindow: View {
    let projectURL: URL
    @State private var store: ProjectStore?
    @State private var sessionLog: SessionLog = .empty
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
                    onSelectChapter: { id in
                        NotificationCenter.default.post(
                            name: .maughamNavigateToDocument,
                            object: nil,
                            userInfo: ["id": id])
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
        } catch {
            self.loadError = error.localizedDescription
        }
    }

    private func reloadSessionLog() async {
        guard let documentStore = store?.documentStore else { return }
        sessionLog = (try? await documentStore.loadSessionLog()) ?? .empty
    }
}
