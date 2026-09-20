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
    /// Another device's streams that this Mac has found SHORTER than it
    /// remembered them (P3a Task 9, spec §4.7). A finding and never a refusal:
    /// the lines that remain are good and stay applied, and what the writer
    /// does about it is reach for a backup.
    ///
    /// Recorded at the load that met it and merely REPORTED here, which is why
    /// it survives a check that judges nobody.
    public let truncatedStreams: [OpLogStore.TruncatedStream]

    public init(
        docSkips: [DocSkips],
        conflictTwins: [String],
        danglingPointers: [IntegrityChecks.DanglingPointer],
        invalidParagraphIds: [IntegrityChecks.InvalidParagraphId] = [],
        unreadableCheckpointFiles: [CheckpointLoad.UnreadableFile] = [],
        truncatedStreams: [OpLogStore.TruncatedStream] = []
    ) {
        self.docSkips = docSkips
        self.conflictTwins = conflictTwins
        self.danglingPointers = danglingPointers
        self.invalidParagraphIds = invalidParagraphIds
        self.unreadableCheckpointFiles = unreadableCheckpointFiles
        self.truncatedStreams = truncatedStreams
    }

    /// `docSkips` only ever holds docs *with* skips (the aggregator filters empties),
    /// so its emptiness alone is the parse-health signal.
    ///
    /// NOTE: since the backup gate moved to `blocksBackup` (2026-08-12), this
    /// has ZERO production consumers — it is the whole-report health signal
    /// the future "Verify project" surface (this type's stated purpose, above)
    /// is meant to take. If that surface ships reading something else, delete
    /// this rather than leave a second unread projection (the
    /// RegionBinding-zero-callers shape).
    public var isHealthy: Bool {
        docSkips.isEmpty && conflictTwins.isEmpty && danglingPointers.isEmpty
            && invalidParagraphIds.isEmpty && unreadableCheckpointFiles.isEmpty
            && truncatedStreams.isEmpty
    }

    /// The findings that BLOCK a backup: the manuscript-derived corruption
    /// signals only. An unreadable checkpoint file is deliberately NOT among
    /// them — it is a finding (`isHealthy` is false, the History pane names
    /// it) but the checkpoint index derives no manuscript text, and its
    /// realistic causes (another device's iCloud dataless stub while offline,
    /// a permissions break) are transient states in which refusing to back up
    /// the writer's words would invert the priority: the manuscript's safety
    /// must not be held hostage by a non-manuscript index (constitution
    /// must #1). The op-log findings DO block, because the backup would
    /// propagate a corrupt or shortened manuscript into every generation.
    ///
    /// A truncated foreign stream is NOT among them either, and for a sharper
    /// reason (P3a Task 9): the surviving lines are exactly what a backup is
    /// for. Refusing to back a manuscript up because part of another device's
    /// history went missing would put the writer's remaining words at risk to
    /// protest the loss of some — the same inversion the checkpoint clause
    /// above refuses.
    ///
    /// Known residue: `danglingPointers` is computed FROM the checkpoint set,
    /// so while a checkpoint file is unreadable that blocking check runs on
    /// incomplete input and can under-report — the backup proceeds on weaker
    /// evidence. Accepted: blocking here would hold the manuscript hostage
    /// again, and the unreadable file is itself a named finding on the report.
    public var blocksBackup: Bool {
        !(docSkips.isEmpty && conflictTwins.isEmpty && danglingPointers.isEmpty
            && invalidParagraphIds.isEmpty)
    }
}

@MainActor
public enum ProjectIntegrity {
    /// `state` is this device's own memory of where other devices' streams
    /// stood (P3a Task 9). It is a parameter rather than `.shared` because
    /// reaching for the process-wide memory would resolve — and on a machine
    /// that has never written, MINT — this device's author key on a path that
    /// asks nothing of it (`RegistryCache.shared`'s own lesson). A caller with
    /// no memory to offer gets a report with no truncations in it, which is
    /// what a reader that has never settled a foreign line honestly knows.
    public static func check(
        projectURL: URL, state: OpLogDeviceState? = nil
    ) async throws -> IntegrityReport {
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
            unreadableCheckpointFiles: checkpointLoad.unreadableFiles,
            // Named by stream rather than by label: this check holds no key and
            // judges nobody, and reading the registry for a NAME would mean a
            // `try?` on a trust reader (RULING-54). The label is the door's —
            // `OpLogStore.truncatedStreams(in:state:trust:)` — for the surface
            // that already holds a verified table.
            truncatedStreams: state.map {
                OpLogStore.truncatedStreams(in: projectURL, state: $0)
            } ?? [])
    }
}
