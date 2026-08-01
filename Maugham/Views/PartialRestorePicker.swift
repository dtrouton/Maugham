// Maugham/Views/PartialRestorePicker.swift
import SwiftUI
import MaughamCore
import os

// Subsystem from the running bundle id so dev/stable logs separate without
// hardcoding "com.maugham" (tripwire 13 spirit).
private let partialRestoreLog = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "com.maugham.Maugham",
    category: "PartialRestore")

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

    /// What `_scope` **actually holds** before the sheet is installed on a
    /// view — the value the picker opens with.
    ///
    /// A read of the `@State`'s own box rather than a second stored property
    /// alongside it, and the difference is not cosmetic: written the other way
    /// this was a copy of `initialScope`'s answer, so planting a raw
    /// `.document(checkpoint.activeDoc)` seed on the line below left it green.
    /// A test of a value beside the one that ships is no test at all.
    var seededScope: ScopeChoice { _scope.wrappedValue }

    enum ScopeChoice: Hashable {
        case wholeProject
        case document(String)
    }

    /// The scope the picker opens on, for a checkpoint whose recorded
    /// `activeDoc` **is not trusted to name a document**.
    ///
    /// The write side stopped recording non-documents
    /// (`CheckpointCapture.documentSubject(of:in:)`), but `checkpoints.jsonl` is
    /// append-only and tripwire 11 rules out a migration, so old rows still hold
    /// a group id or `BinderSubject.noDocumentSubject`. Seeding
    /// `.document(<that>)` opened the radio group on a tag matching none of the
    /// offered rows, and Revert then ran a restore over an id with no op log.
    ///
    /// **The census membership test covers one case a nil-check plus a sentinel
    /// compare would not**: a document recorded honestly and since deleted. It
    /// is the same question the write side asks, asked of a value that arrived
    /// from disk instead of from the binder.
    static func initialScope(for checkpoint: Checkpoint,
                            allDocIds: [String]) -> ScopeChoice {
        guard let docId = CheckpointCapture.documentSubject(
            of: checkpoint.activeDoc, in: allDocIds)
        else { return .wholeProject }
        return .document(docId)
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
        _scope = State(
            initialValue: Self.initialScope(for: checkpoint, allDocIds: allDocIds))
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
                // LOG (can't propagate): `performRestore` is an `async`
                // non-throwing SwiftUI action callback. The restore op is a
                // source-of-truth write — a swallowed `try?` would let the UI
                // report a completed restore while the op never persisted (the
                // restore silently doesn't survive a relaunch). Surface it; we
                // still materialize so the editor shows the intended state.
                do { try await opStore.append(restoreOp) }
                catch {
                    partialRestoreLog.error(
                        "partial-restore op append failed for doc \(docId, privacy: .public): \(error.localizedDescription, privacy: .public)")
                }
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

    /// Derive the post-restore state and push it to disk via DocumentStore.scheduleFileSave.
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
        documentStore?.scheduleFileSave(for: path, text: markdown)
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
