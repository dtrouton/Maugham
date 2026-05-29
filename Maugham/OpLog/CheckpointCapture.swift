import Foundation
import MaughamCore

/// Single entry point for ⌘S and Shift-⌘S. Force-flushes pending bursts on
/// every doc, appends a `checkpoint` breadcrumb op to the active doc's log,
/// and writes a project-wide entry to `checkpoints.jsonl`.
@MainActor
public enum CheckpointCapture {
    public static func run(
        projectURL: URL,
        activeDocId: String,
        allDocIds: [String],
        device: String,
        session: String,
        label: String?
    ) async throws -> Checkpoint {
        let opStore = OpLogStore(projectURL: projectURL)

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
        let cpOp = Op(
            opId: ULID.generate(),
            docId: activeDocId,
            at: Date(),
            device: device,
            session: session,
            kind: .checkpoint,
            changes: [],
            sequence: nil,
            provenance: nil)
        try await opStore.append(cpOp)

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
            resolvedLabel = "\(timeStr) — \(words) words (\(activeDocId))"
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
            activeDoc: activeDocId,
            docPointers: pointers,
            manuscriptWordCount: totalWords)
        try await CheckpointStore(projectURL: projectURL).append(cp)
        return cp
    }
}
