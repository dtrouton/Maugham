import Foundation

/// The gate's two verbs: `approve` puts a staged design round onto the live
/// publish tree, and `revert` takes it back.
///
/// **This is the only thing that writes `.maugham/publish/` on a proposal's
/// behalf.** Staging (`DesignProposalStore`) and sampling (`SampleCompiler`)
/// are deliberately powerless over the live templates — a round is looked at
/// against a scratch copy, and nothing the designer proposed reaches the book's
/// shipping design until the writer says so, here.
///
/// **One versioned, undoable act — and undoable does NOT mean `NSUndoManager`.**
/// The spec's phrase resolves (controller's ruling, pre-made) into two concrete
/// things:
///
/// - *Versioned* is the backup plus the proposal record. Before the first live
///   byte moves, every file this promotion will overwrite is copied whole into
///   `proposals/<id>/backup/files/`, and every staged path that had **no** live
///   counterpart is recorded in `backup/manifest.json` as `created`. The
///   proposal itself carries the other half of the version: who proposed it,
///   which round, what the spec said.
/// - *Undoable* is `revert` — a stored reversal, a verb the writer asks for by
///   name. It is emphatically **not** an `NSUndoManager` registration. A ⌘Z in
///   a text pane undoes a sentence; it must never, at any depth of an undo
///   stack it happens to share, un-ship a book's templates. Those two acts
///   have nothing in common but a keystroke, and the keystroke belongs to the
///   prose.
///
/// **Both verbs refuse while a compile is running.** A compile reads the
/// publish tree file by file over many seconds; swap it underneath one and the
/// book is typeset from half the old design and half the new — an artifact
/// matching no proposal anyone approved, with nothing anywhere reporting a
/// problem. The refusal is a refusal, not a queue: `PublishMintGate`'s
/// discipline, for the same reason (nothing should wait its turn holding the
/// writer's templates hostage).
///
/// **Backup first, whole, then writes.** A promotion is not atomic on disk —
/// nothing here can make several file writes land as one — so the guarantee it
/// gives instead is that the way back is complete before the way forward
/// begins. A promotion that dies halfway leaves a half-swapped tree and a whole
/// backup, and `revert` recovers it byte for byte
/// (`test_aFailureMidWriteLeavesTheBackupWhole_andRevertRecovers`).
@MainActor
enum ProposalPromotion {

    /// What `approve` held back before it wrote, and what `revert` needs to put
    /// things as they were. Written whole, before the first live byte moves,
    /// to `proposals/<id>/backup/manifest.json`.
    struct Backup: Codable, Equatable {
        /// Staged paths that HAD a live counterpart. Their original bytes sit
        /// under `backup/files/<path>`; `revert` copies them back.
        var replaced: [String]
        /// Staged paths that had NO live counterpart. Nothing is stored for
        /// these — there was nothing to store — so `revert` DELETES them.
        /// Without this record, "restore the backup" would leave every file the
        /// round invented standing, which is not what was there before, and the
        /// difference is invisible: a stray partial the templates no longer
        /// `\input` costs nothing until the round after next includes it again.
        var created: [String]
    }

    // MARK: - approve

    /// Promote `proposal`'s staged files onto the live publish tree.
    ///
    /// Vets every staged path before anything is written, backs up what it will
    /// overwrite, records what is new, and only then writes. Marks the proposal
    /// `approved` — the last step, so a proposal is never `approved` over a
    /// promotion that did not finish.
    static func approve(
        proposal: DesignProposalStore.Proposal,
        projectURL: URL,
        jobManager: CompileJobManager
    ) async throws {
        try await refuseWhileCompiling(jobManager)

        let fm = FileManager.default
        let livePublish = livePublishDirectory(projectURL)
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: livePublish.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else { throw Error.noLivePublishTree(projectURL.path) }

        let store = DesignProposalStore(projectURL: projectURL)
        let backupRoot = backupDirectory(id: proposal.id, projectURL: projectURL)
        // A standing backup means the live templates are already held against
        // this proposal. Rebuilding it would capture the PROMOTED bytes as the
        // originals and lose the only way back.
        guard !fm.fileExists(atPath: backupRoot.path) else {
            throw Error.backupAlreadyStands(id: proposal.id)
        }

        let promotions = try resolve(
            proposal: proposal, projectURL: projectURL, livePublish: livePublish)

        // The backup, complete, before the first live write.
        let backupFiles = backupRoot.appendingPathComponent("files", isDirectory: true)
        try fm.createDirectory(at: backupFiles, withIntermediateDirectories: true)
        var backup = Backup(replaced: [], created: [])
        for promotion in promotions {
            guard fm.fileExists(atPath: promotion.destination.path) else {
                backup.created.append(promotion.relativePath)
                continue
            }
            let held = backupFiles.appendingPathComponent(promotion.relativePath)
            try fm.createDirectory(
                at: held.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.copyItem(at: promotion.destination, to: held)
            backup.replaced.append(promotion.relativePath)
        }
        try writeManifest(backup, at: backupRoot)

        for promotion in promotions {
            try fm.createDirectory(
                at: promotion.destination.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            if fm.fileExists(atPath: promotion.destination.path) {
                try fm.removeItem(at: promotion.destination)
            }
            try fm.copyItem(at: promotion.source, to: promotion.destination)
        }

        try store.updateStatus(id: proposal.id, .approved)
    }

    // MARK: - revert

    /// Put the live publish tree back as it was before `proposal` was promoted,
    /// and mark the proposal `rejected` with a note saying so.
    ///
    /// Works on a promotion that FAILED partway as readily as on one that
    /// finished — that is the recovery path, and it is why this reads the
    /// backup rather than the proposal's status.
    ///
    /// The order is restore → reject → discard the backup. If the status write
    /// fails, the backup still stands and a second `revert` recovers; if the
    /// discard fails, the tree is right and the standing backup merely refuses
    /// a re-promotion, which is the safe direction to fail in.
    static func revert(
        proposal: DesignProposalStore.Proposal,
        projectURL: URL,
        jobManager: CompileJobManager,
        note: String? = nil
    ) async throws {
        try await refuseWhileCompiling(jobManager)

        let fm = FileManager.default
        let backupRoot = backupDirectory(id: proposal.id, projectURL: projectURL)
        guard let backup = readManifest(at: backupRoot) else {
            throw Error.noBackupToRestore(id: proposal.id)
        }
        let livePublish = livePublishDirectory(projectURL)
        let backupFiles = backupRoot.appendingPathComponent("files", isDirectory: true)

        for relativePath in backup.replaced {
            let held = backupFiles.appendingPathComponent(relativePath)
            guard fm.fileExists(atPath: held.path) else {
                throw Error.backupFileMissing(relativePath)
            }
            let live = livePublish.appendingPathComponent(relativePath)
            try fm.createDirectory(
                at: live.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fm.fileExists(atPath: live.path) { try fm.removeItem(at: live) }
            try fm.copyItem(at: held, to: live)
        }

        for relativePath in backup.created {
            let live = livePublish.appendingPathComponent(relativePath)
            // Absent is the expected case for a promotion that died before
            // reaching this file — there is nothing to undo about a write that
            // never happened.
            guard fm.fileExists(atPath: live.path) else { continue }
            try fm.removeItem(at: live)
            pruneEmptyDirectories(
                from: live.deletingLastPathComponent(), stoppingAt: livePublish)
        }

        try DesignProposalStore(projectURL: projectURL)
            .reject(id: proposal.id, note: note ?? defaultRevertNote)
        try fm.removeItem(at: backupRoot)
    }

    /// What a revert says when the caller has nothing of its own to say. Never
    /// empty: a `rejected` proposal with no word about why is indistinguishable
    /// from one the writer turned down on sight.
    static let defaultRevertNote =
        "Reverted — the live templates were restored from this proposal's backup."

    // MARK: - the busy-compile guard

    /// Both verbs' first act. `CompileJobManager.allInProgress()` is the
    /// active-job question — the job RECORDS outlive the compile, so a finished
    /// or cancelled job must not refuse anything, or a project that has ever
    /// compiled could never promote again.
    private static func refuseWhileCompiling(_ jobManager: CompileJobManager) async throws {
        let running = await jobManager.allInProgress()
        guard running.isEmpty else {
            throw Error.compileInProgress(jobIDs: running.map(\.jobID))
        }
    }

    // MARK: - paths

    static func livePublishDirectory(_ projectURL: URL) -> URL {
        projectURL.appendingPathComponent(".maugham/publish", isDirectory: true)
    }

    static func backupDirectory(id: String, projectURL: URL) -> URL {
        DesignProposalStore(projectURL: projectURL)
            .proposalDir(id: id)
            .appendingPathComponent("backup", isDirectory: true)
    }

    private struct Promotion {
        let source: URL
        let destination: URL
        let relativePath: String
    }

    /// Every staged file's source and destination, vetted. Runs to completion
    /// before anything is written, so a proposal carrying one bad path refuses
    /// without leaving a half-made backup behind.
    ///
    /// The escape check is defence in depth behind `DesignerReport`'s
    /// parse-time guard — `proposal.json` is a file on disk, and this is the
    /// one place a path that got past that guard would write outside the
    /// publish tree. `SampleCompiler.assembleScratch` keeps the same check for
    /// the same reason.
    private static func resolve(
        proposal: DesignProposalStore.Proposal, projectURL: URL, livePublish: URL
    ) throws -> [Promotion] {
        let fm = FileManager.default
        let stagedDirectory = DesignProposalStore(projectURL: projectURL)
            .proposalDir(id: proposal.id)
            .appendingPathComponent("files", isDirectory: true)
        let root = livePublish.standardizedFileURL.path

        return try proposal.filePaths.map { relativePath in
            let destination = livePublish
                .appendingPathComponent(relativePath).standardizedFileURL
            guard destination.path.hasPrefix(root + "/") else {
                throw Error.stagedPathEscapesThePublishTree(relativePath)
            }
            let source = stagedDirectory.appendingPathComponent(relativePath)
            guard fm.fileExists(atPath: source.path) else {
                throw Error.stagedFileMissing(relativePath)
            }
            return Promotion(
                source: source, destination: destination, relativePath: relativePath)
        }
    }

    /// Walk up from a just-emptied directory removing the empties, so deleting
    /// a file the round invented also takes the folder it invented to hold it.
    /// Stops at the publish root, and stops the moment a directory has anything
    /// in it — the writer's own directories are never at risk.
    private static func pruneEmptyDirectories(from directory: URL, stoppingAt root: URL) {
        let fm = FileManager.default
        let stop = root.standardizedFileURL.path
        var current = directory.standardizedFileURL
        while current.path != stop, current.path.hasPrefix(stop + "/") {
            guard let contents = try? fm.contentsOfDirectory(atPath: current.path),
                  contents.isEmpty
            else { return }
            try? fm.removeItem(at: current)
            current = current.deletingLastPathComponent().standardizedFileURL
        }
    }

    // MARK: - the manifest

    private static func manifestURL(at backupRoot: URL) -> URL {
        backupRoot.appendingPathComponent("manifest.json")
    }

    private static func writeManifest(_ backup: Backup, at backupRoot: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(backup).write(to: manifestURL(at: backupRoot), options: .atomic)
    }

    /// `nil` when there is no backup to restore — an unreadable manifest and an
    /// absent one mean the same thing to a caller: there is no way back on
    /// record, and `revert` must say so rather than half-restore.
    private static func readManifest(at backupRoot: URL) -> Backup? {
        let url = manifestURL(at: backupRoot)
        guard let data = try? Data(contentsOf: url)  // adr-0018-ok: a backup manifest, not manuscript
        else { return nil }
        return try? JSONDecoder().decode(Backup.self, from: data)
    }

    // MARK: - errors

    enum Error: Swift.Error, CustomStringConvertible, Equatable {
        case compileInProgress(jobIDs: [String])
        case noLivePublishTree(String)
        case backupAlreadyStands(id: String)
        case noBackupToRestore(id: String)
        case backupFileMissing(String)
        case stagedPathEscapesThePublishTree(String)
        case stagedFileMissing(String)

        var description: String {
            switch self {
            case .compileInProgress(let jobIDs):
                return "a compile is running (\(jobIDs.joined(separator: ", "))) — "
                    + "changing the templates underneath it would typeset the book "
                    + "from half of each design. Wait for it, or cancel it, then try again."
            case .noLivePublishTree(let path):
                return "no .maugham/publish templates to promote onto in \(path) — "
                    + "run initialize_publish_template first."
            case .backupAlreadyStands(let id):
                return "\(id) has already been promoted and its backup of the live "
                    + "templates still stands. Revert it before promoting it again."
            case .noBackupToRestore(let id):
                return "\(id) has no backup of the live templates, so there is "
                    + "nothing to take back — it was never promoted."
            case .backupFileMissing(let path):
                return "the backup lists \(path) but nothing was held at that path, "
                    + "so the live templates cannot be restored whole."
            case .stagedPathEscapesThePublishTree(let path):
                return "the staged path \(path) points outside .maugham/publish "
                    + "and was refused."
            case .stagedFileMissing(let path):
                return "the proposal lists \(path) but nothing was staged at that path."
            }
        }
    }
}
