// Maugham/Views/CheckpointBrowserPane.swift
import SwiftUI

struct CheckpointBrowserPane: View {
    let projectURL: URL
    let activeDocId: String
    let allDocIds: [String]
    let device: String
    let session: String
    /// Optional path lookup for post-restore materialization (docId → relative path).
    let docPaths: [String: String]
    let documentStore: DocumentStore?

    @State private var checkpoints: [Checkpoint] = []
    @State private var selected: Checkpoint?
    @State private var showingRestorePicker: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Checkpoints")
                .font(.headline)
                .padding(.horizontal)
                .padding(.top, 10)
                .padding(.bottom, 6)
            Divider()
            List(selection: $selected) {
                ForEach(checkpoints.reversed(), id: \.checkpointId) { cp in
                    CheckpointRow(cp: cp)
                        .tag(cp)
                }
            }
            .listStyle(.plain)
            if selected != nil {
                Divider()
                Button("Revert here…") { showingRestorePicker = true }
                    .padding()
            }
        }
        .task { await loadCheckpoints() }
        .sheet(isPresented: $showingRestorePicker) {
            if let cp = selected {
                PartialRestorePicker(
                    checkpoint: cp,
                    projectURL: projectURL,
                    activeDocId: activeDocId,
                    allDocIds: allDocIds,
                    device: device,
                    session: session,
                    docPaths: docPaths,
                    documentStore: documentStore,
                    onComplete: {
                        showingRestorePicker = false
                        Task { await loadCheckpoints() }
                    },
                    onCancel: { showingRestorePicker = false }
                )
            }
        }
    }

    private func loadCheckpoints() async {
        if let loaded = try? await CheckpointStore(projectURL: projectURL).load() {
            checkpoints = loaded
        }
    }
}

// MARK: - Row subview (extracted to avoid type-checker timeout)

private struct CheckpointRow: View {
    let cp: Checkpoint

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(cp.label)
                .font(.body)
            Text(rowDetail)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    private var rowDetail: String {
        "\(cp.at.formatted()) · \(cp.manuscriptWordCount) words · \(cp.activeDoc)"
    }
}
