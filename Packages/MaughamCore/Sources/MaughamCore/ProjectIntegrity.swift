import Foundation

/// A live-project health report: op-log parse skips per doc, dangling checkpoint
/// pointers, and iCloud conflict-twins. The data model behind the future
/// "Verify project" action (UI is a later plan). Backup-generation Merkle
/// verification is separate.
public struct IntegrityReport: Equatable, Sendable {
    public struct DocSkips: Equatable, Sendable {
        public let docId: String
        public let skipped: [ParseDiagnostics.SkippedLine]
        public init(docId: String, skipped: [ParseDiagnostics.SkippedLine]) {
            self.docId = docId
            self.skipped = skipped
        }
    }
    public let docSkips: [DocSkips]
    public let conflictTwins: [String]
    public let danglingPointers: [IntegrityChecks.DanglingPointer]
    public let invalidParagraphIds: [IntegrityChecks.InvalidParagraphId]
    /// Checkpoint device files that exist but could not be read (RULING-54).
    /// An unreadable file used to read as EMPTY through `try? … ?? []`, which
    /// *reduced* this report's findings — fewer checkpoints meant fewer
    /// dangling pointers to find — exactly when the project was least healthy.
    public let unreadableCheckpointFiles: [CheckpointLoad.UnreadableFile]

    public init(
        docSkips: [DocSkips],
        conflictTwins: [String],
        danglingPointers: [IntegrityChecks.DanglingPointer],
        invalidParagraphIds: [IntegrityChecks.InvalidParagraphId] = [],
        unreadableCheckpointFiles: [CheckpointLoad.UnreadableFile] = []
    ) {
        self.docSkips = docSkips
        self.conflictTwins = conflictTwins
        self.danglingPointers = danglingPointers
        self.invalidParagraphIds = invalidParagraphIds
        self.unreadableCheckpointFiles = unreadableCheckpointFiles
    }

    /// `docSkips` only ever holds docs *with* skips (the aggregator filters empties),
    /// so its emptiness alone is the parse-health signal.
    public var isHealthy: Bool {
        docSkips.isEmpty && conflictTwins.isEmpty && danglingPointers.isEmpty
            && invalidParagraphIds.isEmpty && unreadableCheckpointFiles.isEmpty
    }
}

@MainActor
public enum ProjectIntegrity {
    public static func check(projectURL: URL) async throws -> IntegrityReport {
        let opsDir = projectURL.appendingPathComponent(".maugham/ops")
        let filenames = ((try? FileManager.default.contentsOfDirectory(
            at: opsDir, includingPropertiesForKeys: nil)) ?? []).map(\.lastPathComponent)

        var docSkips: [IntegrityReport.DocSkips] = []
        var opsByDoc: [String: Set<String>] = [:]
        var allOps: [Op] = []
        for docId in OpLogStore.docIds(inOpsDirectoryFilenames: filenames).sorted() {
            var skips: [ParseDiagnostics.SkippedLine] = []
            var opIds: Set<String> = []
            for url in OpLogStore.opLogFileURLs(forDocId: docId, in: projectURL) {
                // Shared per-file loader: plain `.jsonl` tail or sealed `.mzseg`
                // segment, so opIds inside segments stay visible to the
                // dangling-pointer check exactly as tail opIds are. Without this
                // a `.mzseg` would be JSONL-parsed as garbage and every segment
                // would surface as parse skips (growth spec §5.4).
                let result = try await OpLogStore.loadFileDiagnosed(url: url, presenter: nil)
                skips.append(contentsOf: result.diagnostics.skipped)
                opIds.formUnion(result.ops.map(\.opId))
                allOps.append(contentsOf: result.ops)
            }
            if !skips.isEmpty { docSkips.append(.init(docId: docId, skipped: skips)) }
            opsByDoc[docId] = opIds
        }

        let checkpointLoad = await CheckpointStore(projectURL: projectURL).load()
        let dangling = IntegrityChecks.danglingCheckpointPointers(
            checkpoints: checkpointLoad.checkpoints, opsByDoc: opsByDoc)

        return IntegrityReport(
            docSkips: docSkips,
            conflictTwins: IntegrityChecks.conflictTwins(inOpsDirectoryFilenames: filenames),
            danglingPointers: dangling,
            invalidParagraphIds: IntegrityChecks.invalidParagraphIds(inOps: allOps),
            unreadableCheckpointFiles: checkpointLoad.unreadableFiles)
    }
}
