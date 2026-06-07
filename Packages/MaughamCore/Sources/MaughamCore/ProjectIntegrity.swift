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

    public init(
        docSkips: [DocSkips],
        conflictTwins: [String],
        danglingPointers: [IntegrityChecks.DanglingPointer],
        invalidParagraphIds: [IntegrityChecks.InvalidParagraphId] = []
    ) {
        self.docSkips = docSkips
        self.conflictTwins = conflictTwins
        self.danglingPointers = danglingPointers
        self.invalidParagraphIds = invalidParagraphIds
    }

    /// `docSkips` only ever holds docs *with* skips (the aggregator filters empties),
    /// so its emptiness alone is the parse-health signal.
    public var isHealthy: Bool {
        docSkips.isEmpty && conflictTwins.isEmpty && danglingPointers.isEmpty
            && invalidParagraphIds.isEmpty
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
                let store = JSONLAppendStore<Op>(
                    fileURL: url,
                    dedupKey: { $0.opId },
                    sortedBy: { $0.opId < $1.opId })
                let result = try await store.loadDiagnosed()
                skips.append(contentsOf: result.diagnostics.skipped)
                opIds.formUnion(result.elements.map(\.opId))
                allOps.append(contentsOf: result.elements)
            }
            if !skips.isEmpty { docSkips.append(.init(docId: docId, skipped: skips)) }
            opsByDoc[docId] = opIds
        }

        let checkpoints = (try? await CheckpointStore(projectURL: projectURL).load()) ?? []
        let dangling = IntegrityChecks.danglingCheckpointPointers(
            checkpoints: checkpoints, opsByDoc: opsByDoc)

        return IntegrityReport(
            docSkips: docSkips,
            conflictTwins: IntegrityChecks.conflictTwins(inOpsDirectoryFilenames: filenames),
            danglingPointers: dangling,
            invalidParagraphIds: IntegrityChecks.invalidParagraphIds(inOps: allOps))
    }
}
