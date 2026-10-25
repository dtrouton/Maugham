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
    /// The book's registered figures (report plan 6c Task 3, rulings Q-1–Q-3):
    /// a revert winds back each one in scope that has a pointer in the
    /// checkpoint.
    let figures: [FigureRecord]
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
        figures: [FigureRecord] = [],
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
        self.figures = figures
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
        let offered = Self.offeredDocIds(allDocIds, mayWrite: mayWrite)
        RestorePickerContent(
            checkpoint: checkpoint,
            allDocIds: offered,
            titles: Self.titles(
                of: offered, in: documentStore?.projectStore?.manifest.structure),
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

    /// What the sheet says when the door left documents alone — by their
    /// TITLES (P3c plan 2 Task 9; the sentence named raw doc ids), in Replace
    /// All's own words (`ProjectStore.leftAloneSentence`), since both say the
    /// same thing about the same kind of refusal.
    static func leftAloneSentence(
        for docIds: [String], in structure: [StructureItem]?
    ) -> String? {
        ProjectStore.leftAloneSentence(titles(of: docIds, in: structure))
    }

    /// Each document's title from the window's live manifest; a document the
    /// manifest does not name (or no manifest at all) is named by its id
    /// rather than dropped, so the sentence never under-reports.
    static func titles(of docIds: [String], in structure: [StructureItem]?) -> [String] {
        docIds.map { id in
            structure.flatMap { TreeWalk.find(id: id, in: $0)?.title } ?? id
        }
    }

    // MARK: - Restore logic

    private func performRestore() async {
        // No scope chosen means the checkpoint named no document and the writer
        // has not picked one; `Revert` is disabled in that state, so this is a
        // belt-and-braces refusal rather than a reachable path.
        guard let scope else { return }
        isRestoring = true
        let sentence = await restore(scope)
        isRestoring = false
        if let sentence {
            leftAloneSentence = sentence
            return
        }
        onComplete()
    }

    /// **The revert itself**: the text of every document in `scope` this Mac
    /// may write, then its figures (`restoreFigures`). Answers what the sheet
    /// says when something was left as it was or only partly restored, or
    /// `nil` when everything asked for was done.
    func restore(_ scope: ScopeChoice) async -> String? {
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
        let figureResults = await Self.restoreFigures(
            Self.figuresInScope(figures, scope, of: checkpoint),
            to: checkpoint, documentStore: documentStore)
        let sentences = [
            Self.leftAloneSentence(
                for: leftAlone, in: documentStore?.projectStore?.manifest.structure),
            Self.figureSentence(for: figureResults),
        ].compactMap { $0 }
        return sentences.isEmpty ? nil : sentences.joined(separator: " ")
    }

    // MARK: - Figures (report plan 6c Task 3, rulings Q-1, Q-2, Q-3)

    /// What reverting one figure came to.
    enum FigureResult: Equatable {
        /// Its host's answer (`FigureRestoreOutcome`).
        case outcome(FigureRestoreOutcome)
        /// The figure's door refused `.editFigure`: nothing was appended.
        case refused
        /// The restore threw before any op landed (the error's description).
        case failed(String)
    }

    /// **The figures a revert reaches** (Q-1, Q-3): whole project, every
    /// registered figure; a document, the figures whose piece it is. Only
    /// those with a pointer in the checkpoint — one created since has none
    /// and is left alone, as is a pointer whose figure is no longer
    /// registered (it is not in `figures`).
    static func figuresInScope(
        _ figures: [FigureRecord], _ scope: ScopeChoice, of checkpoint: Checkpoint
    ) -> [FigureRecord] {
        figures.filter { record in
            guard checkpoint.docPointers[record.id] != nil else { return false }
            switch scope {
            case .wholeProject: return true
            case .document(let docId): return record.piece == docId
            }
        }
    }

    /// **Each figure wound back through its host** — the open one, or one
    /// opened for this and released after (`DocumentStore.closeFigure`).
    /// Each asks its own door first (`settledPosture(forDocId:)`, `.editFigure`,
    /// Q-2); no `DocumentStore` behind the sheet fails closed. The figure at
    /// the checkpoint is the fold of the host's own ops through the pointer
    /// (`FigureRestoreDiff.target`). Not registered for ⌘Z, like the text.
    static func restoreFigures(
        _ figures: [FigureRecord], to checkpoint: Checkpoint, documentStore: DocumentStore?
    ) async -> [(record: FigureRecord, result: FigureResult)] {
        var results: [(record: FigureRecord, result: FigureResult)] = []
        for record in figures {
            guard let pointer = checkpoint.docPointers[record.id] else { continue }
            guard let documentStore,
                  await documentStore.settledPosture(forDocId: record.id).allows(.editFigure) else {
                results.append((record, .refused))
                continue
            }
            let wasOpen = documentStore.openFigure(forId: record.id) != nil
            let result: FigureResult
            do {
                let host = try await documentStore.openFigure(figureId: record.id)
                let target = FigureRestoreDiff.target(of: host._ops, through: pointer)
                result = .outcome(try await host.restoreToCheckpoint(
                    checkpoint.checkpointId, target: target))
            } catch is FigureEditRefused {
                result = .refused
            } catch {
                partialRestoreLog.error(
                    "partial-restore failed for figure \(record.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
                result = .failed(error.localizedDescription)
            }
            if !wasOpen { await documentStore.closeFigure(figureId: record.id) }
            results.append((record, result))
        }
        return results
    }

    /// What the sheet says about the figures a revert did not fully restore,
    /// by name, beside the documents it left alone; `nil` when every figure
    /// in scope was restored or already stood as it did then.
    static func figureSentence(
        for results: [(record: FigureRecord, result: FigureResult)]
    ) -> String? {
        var refused: [String] = [], parked: [String] = [], pictures: [String] = []
        var partly: [String] = [], failed: [String] = []
        for (record, result) in results {
            switch result {
            case .refused: refused.append(record.name)
            case .failed(let why): failed.append("\(record.name) (\(why))")
            case .outcome(.skippedParked): parked.append(record.name)
            case .outcome(.skippedPicture): pictures.append(record.name)
            case .outcome(.partlyRestored): partly.append(record.name)
            case .outcome(.restored), .outcome(.unchanged): break
            }
        }
        func list(_ names: [String]) -> String { names.joined(separator: ", ") }
        var sentences: [String] = []
        if !refused.isEmpty {
            sentences.append("Left as it was — this Mac may not change the "
                + (refused.count == 1 ? "figure " : "figures ") + list(refused) + ".")
        }
        if !parked.isEmpty {
            sentences.append("Not restored, in Research — bring it back first: \(list(parked)).")
        }
        if !pictures.isEmpty {
            sentences.append("The rest restored, but the picture from then is no longer on disk: \(list(pictures)).")
        }
        if !partly.isEmpty {
            sentences.append("Partly restored — revert again to finish: \(list(partly)).")
        }
        if !failed.isEmpty {
            sentences.append("Not restored: \(list(failed)).")
        }
        return sentences.isEmpty ? nil : sentences.joined(separator: " ")
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
    /// The rows' names, parallel to `allDocIds` — titles, not ids (Task 9).
    let titles: [String]
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
                ForEach(Array(zip(allDocIds, titles)), id: \.0) { docId, title in
                    Text("Document: \(title)")
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
