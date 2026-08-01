import Foundation
import MaughamCore

/// Single entry point for ⌘S and Shift-⌘S. Force-flushes pending bursts on
/// every doc, appends a `checkpoint` breadcrumb op to the active doc's log —
/// *when the subject is one of the project's documents* — and writes a
/// project-wide entry to `checkpoints.jsonl`.
@MainActor
public enum CheckpointCapture {
    /// Runs a checkpoint.
    ///
    /// - Parameter activeDocId: What the window's tree names. **Not trusted to
    ///   be a document** — see `documentSubject(of:in:)`.
    /// - Parameter allDocIds: The project's document census, and therefore also
    ///   the answer to *"is `activeDocId` a document?"*.
    public static func run(
        projectURL: URL,
        activeDocId: String,
        allDocIds: [String],
        device: String,
        session: String,
        label: String?,
        activeDocument: Document? = nil
    ) async throws -> Checkpoint {
        let opStore = OpLogStore(projectURL: projectURL)

        // ONE decision, and everything below that needs a document id reads
        // THIS value: the breadcrumb op's `docId`, the auto-label's
        // parenthetical, and the `activeDoc` the checkpoint records. The same
        // id travelling three distances, and a fix applied to fewer than all of
        // them is how they drift — the label and the record are pinned together
        // by `CheckpointSubjectRecordTests.test_theLabelAndTheRecordCannotDisagree`,
        // which goes red on a half-fix in either direction.
        let subjectDoc: String? = documentSubject(of: activeDocId, in: allDocIds)

        // doc_pointers = last op_id per doc.
        var pointers: [String: String] = [:]
        for docId in allDocIds {
            if let last = try await opStore.load(docId: docId).last {
                pointers[docId] = last.opId
            }
        }

        // Breadcrumb op on the active doc. The op is appended to the log as a
        // marker but the pointer for the active doc stays pointing at the last
        // content op (captured above), so restore targets meaningful content.
        //
        // SKIPPED ENTIRELY when the subject is not a document — see
        // `documentSubject(of:in:)`. Everything below this block runs either
        // way: ⌘S is a labeled checkpoint, and the writer gets their checkpoint.
        if let subjectDoc {
            let cpOp = Op(
                opId: ULID.generate(),
                docId: subjectDoc,
                at: Date(),
                device: device,
                session: session,
                kind: .checkpoint,
                changes: [],
                sequence: nil,
                provenance: nil)

            // If the live Document is provided, route the append through it so
            // its _opLogMirror learns the cpOp's opId. The existing opId-set echo
            // guard in Document+ExternalChange then filters this write on the next
            // NSFilePresenter callback, avoiding a redundant re-derive on every ⌘S.
            // When no live Document is supplied (no open doc / older callers /
            // tests that don't pass one), fall back to the fresh opStore so
            // behaviour is unchanged.
            if let activeDocument {
                try await activeDocument.appendMirrored(cpOp)
            } else {
                try await opStore.append(cpOp)
            }
        }

        // Compute word count over all docs.
        var totalWords = 0
        for docId in allDocIds {
            let ops = try await opStore.load(docId: docId)
            let state = Deriver.derive(ops: ops)
            totalWords += state.paragraphs.values
                .map { $0.split { $0.isWhitespace || $0.isNewline }.count }
                .reduce(0, +)
        }

        // Auto-label or user-supplied.
        let resolvedLabel: String
        let labelSource: Checkpoint.LabelSource
        if let userLabel = label, !userLabel.isEmpty {
            resolvedLabel = userLabel
            labelSource = .user
        } else {
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm"
            let timeStr = formatter.string(from: Date())
            let words = totalWords.formatted(.number)
            // The parenthetical says WHICH DOCUMENT you were in. When you were
            // in none it says nothing — not the project's title, which would
            // sit in a slot that otherwise always holds a document name and
            // read as though a document by that name existed (Denver's ruling).
            // Checkpoints are project-wide either way.
            let subjectSuffix = subjectDoc.map { " (\($0))" } ?? ""
            resolvedLabel = "\(timeStr) — \(words) words\(subjectSuffix)"
            labelSource = .auto
        }

        // Snap `at` to millisecond precision so the ISO8601-with-fractional-seconds
        // encoder (which has 3 decimal places → ms precision) round-trips back to
        // an equal Date. Date internally uses sub-millisecond precision that would
        // otherwise be lost on the encode→decode path.
        let now = Date()
        let snappedAt = Date(timeIntervalSince1970: (now.timeIntervalSince1970 * 1000).rounded() / 1000)
        let cp = Checkpoint(
            checkpointId: ULID.generate(),
            label: resolvedLabel,
            labelSource: labelSource,
            at: snappedAt,
            device: device,
            activeDoc: subjectDoc,
            docPointers: pointers,
            manuscriptWordCount: totalWords)
        try await CheckpointStore(projectURL: projectURL).append(cp)
        return cp
    }

    /// The manuscript document a checkpoint's subject names, or `nil` when it
    /// names something that is not one.
    ///
    /// **The one answer to *"is this a document?"* for everything
    /// checkpoint-shaped** — the breadcrumb op's stream, the auto-label's
    /// parenthetical, the `activeDoc` the record carries, and (on the read side)
    /// the scope `PartialRestorePicker` opens with. Every one of those, one
    /// membership test; a second spelling of it somewhere is free to disagree
    /// with this one, which is the whole reason it is a named function rather
    /// than an `if` in each place.
    ///
    /// **The guard is here rather than at either ⌘S call site, because there are
    /// two of them** — `ProjectWindow`'s Shift-⌘S label sheet and
    /// `CheckpointModifier`'s ⌘S key command — and a guard at one fixes half the
    /// defect. `run` is the only code in the app that appends a `.checkpoint` op
    /// (censused by `CheckpointBreadcrumbSubjectTests`), so this is the one place
    /// the decision can be made once.
    ///
    /// **What it was before:** nothing. The window's subject may be a group, or
    /// the project, or `BinderSubject.noDocumentSubject`, and every one of those
    /// minted `.maugham/ops/<not-a-doc>.<slug>.jsonl` with a single op in it.
    /// `OpLogStore.docId(fromOpLogFilename:)` excludes exactly one synthetic
    /// stream — `__project__` — so such a file parses as a real doc id from then
    /// on: sealed on every project open by `DocumentStore`, enumerated and
    /// downloaded on the phone by `AnnotationsStore` and `ColdLaunchDownloader`.
    /// The binder's project row turns that from an edge case into the default
    /// outcome of *"select the project, press ⌘S"*.
    ///
    /// **Why `allDocIds` is the right question to ask, and not a second answer
    /// to it.** Deciding *"is this a manuscript document?"* is
    /// `TreeWalk.find(id:in:)` plus `item.type == .document` against the manifest
    /// everywhere else in the app — and `allDocIds` is literally the result of
    /// that walk: `ProjectWindow.documentIds(in:)` is
    /// `TreeWalk.collect(where: { $0.type == .document }).map(\.id)`. This
    /// function re-uses the census the caller already computed rather than
    /// re-deriving it from a manifest `run` would otherwise have no reason to
    /// read. It is also the same set `run` has just walked for `docPointers`: a
    /// breadcrumb belongs on a stream whose pointer we took.
    ///
    /// **NOT redirected to `__project__`.** That stream carries project-scope
    /// *task* ops and is walked by `TaskDeriver`, `TasksPane.ownerDoc` and
    /// `ProjectStore.projectTasksOpLog()`; a breadcrumb in it would be a second
    /// op kind in a log those three read. The op is dropped, not re-homed.
    ///
    /// **`candidate` is optional so the read side can ask the same question.**
    /// A checkpoint already on disk may hold `nil`, a group id, the sentinel, or
    /// a document since deleted, and every one of those is the same answer.
    ///
    /// `nonisolated` because the read side asks it from a `View`'s initializer:
    /// it is a pure membership test over its two arguments and touches nothing
    /// the main actor owns.
    nonisolated static func documentSubject(of candidate: String?,
                                            in allDocIds: [String]) -> String? {
        guard let candidate, allDocIds.contains(candidate) else { return nil }
        return candidate
    }
}
