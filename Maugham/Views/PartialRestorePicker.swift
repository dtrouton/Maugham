// Maugham/Views/PartialRestorePicker.swift
import SwiftUI

struct PartialRestorePicker: View {
    let checkpoint: Checkpoint
    let projectURL: URL
    let activeDocId: String
    let allDocIds: [String]
    let device: String
    let session: String
    /// docId → relative file path, for post-restore materialization.
    let docPaths: [String: String]
    let documentStore: DocumentStore?
    let onComplete: () -> Void
    let onCancel: () -> Void

    @State private var scope: ScopeChoice
    @State private var isRestoring: Bool = false

    enum ScopeChoice: Hashable {
        case wholeProject
        case document(String)
    }

    init(
        checkpoint: Checkpoint,
        projectURL: URL,
        activeDocId: String,
        allDocIds: [String],
        device: String,
        session: String,
        docPaths: [String: String],
        documentStore: DocumentStore?,
        onComplete: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.checkpoint = checkpoint
        self.projectURL = projectURL
        self.activeDocId = activeDocId
        self.allDocIds = allDocIds
        self.device = device
        self.session = session
        self.docPaths = docPaths
        self.documentStore = documentStore
        self.onComplete = onComplete
        self.onCancel = onCancel
        _scope = State(initialValue: .document(checkpoint.activeDoc))
    }

    var body: some View {
        RestorePickerContent(
            checkpoint: checkpoint,
            allDocIds: allDocIds,
            scope: $scope,
            isRestoring: isRestoring,
            onCancel: onCancel,
            onRevert: { Task { await performRestore() } }
        )
    }

    // MARK: - Restore logic

    private func performRestore() async {
        isRestoring = true
        let opStore = OpLogStore(projectURL: projectURL)
        let docs: [String]
        switch scope {
        case .wholeProject:
            docs = allDocIds
        case .document(let id):
            docs = [id]
        }
        for docId in docs {
            let allOps = (try? await opStore.load(docId: docId)) ?? []
            let current = Deriver.derive(ops: allOps)
            let targetOpId = checkpoint.docPointers[docId]
            let pastOps = allOps.prefix(while: { op in
                guard let target = targetOpId else { return true }
                return op.opId <= target
            })
            let target = Deriver.derive(ops: Array(pastOps))
            if let restoreOp = Restore.buildRestoreOp(
                current: current,
                target: target,
                scope: .document,
                docId: docId,
                device: device,
                session: session,
                sourceCheckpoint: checkpoint.checkpointId
            ) {
                try? await opStore.append(restoreOp)
                // Materialize the new state and schedule a save so the .md
                // on disk (and the editor) reflects the restored content.
                materializeAndScheduleSave(
                    docId: docId,
                    newState: target,
                    restoreOp: restoreOp
                )
            }
        }
        isRestoring = false
        onComplete()
    }

    /// Derive the post-restore state and push it to disk via DocumentStore.scheduleSave.
    private func materializeAndScheduleSave(
        docId: String,
        newState: Deriver.DerivedState,
        restoreOp: Op
    ) {
        guard let path = docPaths[docId] else { return }
        // Incorporate the restore op into the state so the sequence is updated.
        let finalState: Deriver.DerivedState
        if let seq = restoreOp.sequence {
            // The restore op carries an updated sequence — use it.
            var paragraphs = newState.paragraphs
            for change in restoreOp.changes {
                paragraphs[change.paragraphId] = change.next
            }
            finalState = Deriver.DerivedState(paragraphs: paragraphs, sequence: seq)
        } else {
            // No explicit sequence in the restore op; use target state as-is.
            finalState = newState
        }
        let markdown = Materializer.materialize(
            paragraphs: finalState.paragraphs,
            sequence: finalState.sequence
        )
        documentStore?.scheduleSave(for: path, text: markdown)
    }
}

// MARK: - Content subview (extracted to avoid type-checker timeout)

private struct RestorePickerContent: View {
    let checkpoint: Checkpoint
    let allDocIds: [String]
    @Binding var scope: PartialRestorePicker.ScopeChoice
    let isRestoring: Bool
    let onCancel: () -> Void
    let onRevert: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Revert to \u{201C}\(checkpoint.label)\u{201D}")
                .font(.headline)
            Picker("Scope", selection: $scope) {
                Text("Whole project").tag(PartialRestorePicker.ScopeChoice.wholeProject)
                ForEach(allDocIds, id: \.self) { docId in
                    Text("Document: \(docId)")
                        .tag(PartialRestorePicker.ScopeChoice.document(docId))
                }
            }
            .pickerStyle(.radioGroup)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { onCancel() }
                    .disabled(isRestoring)
                Button("Revert") { onRevert() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(isRestoring)
            }
        }
        .padding(20)
        .frame(minWidth: 360)
    }
}
