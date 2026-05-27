import SwiftUI

/// Small status pill that becomes visible when a compile job is in progress
/// for this project. Hidden when idle.
///
/// Polls `CompileJobManager.allInProgress()` every 500ms. Polling is
/// acceptable for v1; a push-based notification from the job manager is the
/// natural follow-up. (See plan Phase 8 task 44.)
@MainActor
struct PublishStatusPill: View {

    let projectID: String
    let projectURL: URL

    @State private var inFlight: CompileJob? = nil
    @State private var pollTask: Task<Void, Never>? = nil

    var body: some View {
        Group {
            if let job = inFlight, case .inProgress(let phase) = job.status {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(label(for: phase))
                        .font(.caption)
                        .lineLimit(1)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color.accentColor.opacity(0.15), in: Capsule())
                .accessibilityLabel("Publishing: \(label(for: phase))")
            }
        }
        .onAppear { startPolling() }
        .onDisappear { pollTask?.cancel(); pollTask = nil }
    }

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { @MainActor in
            while !Task.isCancelled {
                let stores = PublishingStores.sharedFor(
                    projectID: projectID, projectURL: projectURL)
                let jobs = await stores.jobManager.allInProgress()
                self.inFlight = jobs.last
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
    }

    private func label(for phase: CompileJob.Phase) -> String {
        switch phase {
        case .fetchingPackages: return "Fetching LaTeX packages…"
        case .renderingBody:    return "Rendering body…"
        case .compiling:        return "Compiling…"
        case .writingOutput:    return "Writing output…"
        }
    }
}
