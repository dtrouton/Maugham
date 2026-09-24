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

    @State private var scope: ScopeChoice?
    @State private var isRestoring: Bool = false
    /// Set when the restore door left documents alone (P3c whole-branch fix
    /// wave, C1): the sheet stays up and says which, rather than closing over
    /// a revert that did less than it was asked.
    @State private var leftAloneSentence: String?

    /// What `_scope` **actually holds** before the sheet is installed on a
    /// view — the value the picker opens with.
    ///
    /// A read of the `@State`'s own box rather than a second stored property
    /// alongside it, and the difference is not cosmetic: written the other way
    /// this was a copy of `initialScope`'s answer, so planting a raw
    /// `.document(checkpoint.activeDoc)` seed on the line below left it green.
    /// A test of a value beside the one that ships is no test at all.
    var seededScope: ScopeChoice? { _scope.wrappedValue }

    enum ScopeChoice: Hashable {
        case wholeProject
        case document(String)
    }

    /// The scope the picker opens on, or **`nil` when the checkpoint gives no
    /// grounds to prefer one** — for a checkpoint whose recorded `activeDoc` is
    /// not trusted to name a document.
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
    ///
    /// **Why `nil` rather than `.wholeProject`** (Denver's ruling, 2026-08-02).
    /// A checkpoint that names no document has not lost the ability to restore
    /// one — `performRestore` reads `checkpoint.docPointers[docId]`, and a
    /// checkpoint carries pointers for **every** document, so either scope is
    /// available. What it has lost is only the *hint*. Defaulting to
    /// `.wholeProject` would arm `Revert`'s `.defaultAction` on rows already on
    /// disk: before this, that same Return was a silent no-op (the seeded tag
    /// matched no row, and `Restore.buildRestoreOp` returns nil for an empty
    /// diff), so one keystroke would have gone from doing nothing to reverting
    /// every document — with no undo registered on this path. The sheet now
    /// says what is true: both are possible, neither is indicated.
    static func initialScope(for checkpoint: Checkpoint,
                            allDocIds: [String]) -> ScopeChoice? {
        // The degenerate case is the one place a preselection is still honest:
        // with no documents to offer, the whole project is the ONLY restore
        // available, so showing it selected is showing what is possible rather
        // than guessing. (Functionally a no-op — `performRestore` would iterate
        // an empty list — but the sheet should not open with a disabled button
        // and a single unchosen row.)
        guard !allDocIds.isEmpty else { return .wholeProject }
        guard let docId = CheckpointCapture.documentSubject(
            of: checkpoint.activeDoc, in: allDocIds)
        else { return nil }
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
        let mayWrite = Self.mayWrite(through: documentStore)
        RestorePickerContent(
            checkpoint: checkpoint,
            allDocIds: Self.offeredDocIds(allDocIds, mayWrite: mayWrite),
            offersWholeProject: Self.offersWholeProject(allDocIds, mayWrite: mayWrite),
            scope: $scope,
            // A seeded scope this Mac may not write selects no row and arms
            // nothing — the same shape as the seed that names no document.
            scopeIsOffered: Self.offered(
                scope, allDocIds: allDocIds, mayWrite: mayWrite) != nil,
            isRestoring: isRestoring,
            leftAloneSentence: leftAloneSentence,
            onCancel: onCancel,
            onRevert: { Task { await performRestore() } },
            onDone: onComplete
        )
    }

    // MARK: - Posture (P3c whole-branch fix wave, C1)

    /// The drawing answer for one document: may this Mac write its text? No
    /// door behind the host fails CLOSED.
    static func mayWrite(through documentStore: DocumentStore?) -> (String) -> Bool {
        { docId in documentStore?.posture(forDocId: docId).allows(.writeText) ?? false }
    }

    /// **The documents the picker lists** — the ones this Mac may write. A
    /// revert rewrites a document's text, so a reviewer is offered none (and
    /// History draws no *Revert here…* to open the sheet at all).
    static func offeredDocIds(
        _ allDocIds: [String], mayWrite: (String) -> Bool
    ) -> [String] {
        allDocIds.filter(mayWrite)
    }

    /// *Whole project* only where every document is this Mac's to write — a
    /// whole-project revert that skipped some would not be what it says.
    static func offersWholeProject(
        _ allDocIds: [String], mayWrite: (String) -> Bool
    ) -> Bool {
        allDocIds.allSatisfy(mayWrite)
    }

    /// A scope, kept only where the picker offers it.
    static func offered(
        _ seeded: ScopeChoice?, allDocIds: [String], mayWrite: (String) -> Bool
    ) -> ScopeChoice? {
        switch seeded {
        case .wholeProject?:
            return offersWholeProject(allDocIds, mayWrite: mayWrite) ? .wholeProject : nil
        case .document(let id)?:
            return mayWrite(id) ? .document(id) : nil
        case nil:
            return nil
        }
    }

    /// **The door** (P3c whole-branch fix wave, C1): a revert appends a
    /// `.checkpointRestore`, which the table classes as manuscript text, so
    /// each document is asked the ACTING answer (controller ruling I) before
    /// anything is built. No `DocumentStore` behind the sheet fails closed.
    static func splitByTheDoor(
        _ docIds: [String], documentStore: DocumentStore?
    ) async -> (writable: [String], leftAlone: [String]) {
        var writable: [String] = []
        var leftAlone: [String] = []
        for docId in docIds {
            if let documentStore,
               await documentStore.settledPosture(forDocId: docId).allows(.writeText) {
                writable.append(docId)
            } else {
                leftAlone.append(docId)
            }
        }
        return (writable, leftAlone)
    }

    /// What the sheet says when the door left documents alone.
    static func leftAloneSentence(for docIds: [String]) -> String? {
        guard !docIds.isEmpty else { return nil }
        return "Left as it was — this Mac may not change the text of "
            + docIds.joined(separator: ", ") + "."
    }

    // MARK: - Restore logic

    private func performRestore() async {
        // No scope chosen means the checkpoint named no document and the writer
        // has not picked one; `Revert` is disabled in that state, so this is a
        // belt-and-braces refusal rather than a reachable path.
        guard let scope else { return }
        isRestoring = true
        let opStore = OpLogStore(projectURL: projectURL)
        let docs: [String]
        switch scope {
        case .wholeProject:
            docs = allDocIds
        case .document(let id):
            docs = [id]
        }
        let (writable, leftAlone) = await Self.splitByTheDoor(docs, documentStore: documentStore)
        for docId in writable {
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
        if let sentence = Self.leftAloneSentence(for: leftAlone) {
            leftAloneSentence = sentence
            return
        }
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
    let offersWholeProject: Bool
    @Binding var scope: PartialRestorePicker.ScopeChoice?
    let scopeIsOffered: Bool
    let isRestoring: Bool
    let leftAloneSentence: String?
    let onCancel: () -> Void
    let onRevert: () -> Void
    let onDone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Revert to \u{201C}\(checkpoint.label)\u{201D}")
                .font(.headline)
            // Tags are OPTIONAL to match the selection's type — a non-optional
            // tag against a `Binding<ScopeChoice?>` matches nothing, and the
            // radio group would render with no row ever selectable.
            Picker("Scope", selection: $scope) {
                if offersWholeProject {
                    Text("Whole project")
                        .tag(PartialRestorePicker.ScopeChoice?.some(.wholeProject))
                }
                ForEach(allDocIds, id: \.self) { docId in
                    Text("Document: \(docId)")
                        .tag(PartialRestorePicker.ScopeChoice?.some(.document(docId)))
                }
            }
            .pickerStyle(.radioGroup)
            if let leftAloneSentence {
                Text(leftAloneSentence)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                if leftAloneSentence != nil {
                    Button("Done") { onDone() }
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("Cancel", role: .cancel) { onCancel() }
                        .disabled(isRestoring)
                    // Disabled until a scope is chosen. `.defaultAction` means
                    // Return fires this button, and for a checkpoint that names
                    // no document there is nothing the writer has asked for yet.
                    Button("Revert") { onRevert() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(isRestoring || scope == nil || !scopeIsOffered)
                }
            }
        }
        .padding(20)
        .frame(minWidth: 360)
    }
}
