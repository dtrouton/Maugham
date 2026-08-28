import Foundation

/// Where a design round's proposed templates stage for the writer's review,
/// under `.maugham/design/proposals/<proposalId>/`.
///
/// **Everything here is DERIVED.** A staged proposal is a reviewable COPY of
/// what a designer session (`DesignerReport`) proposed — never the live
/// templates it proposes to replace (those stay under `.maugham/publish/`,
/// untouched until approval — Task 8) and never the manuscript its samples
/// are drawn from (plain text at the writer's own paths). Deleting
/// `.maugham/design/` costs proposals — a design round the writer would have
/// to ask for again — and never a word the writer wrote (CLAUDE.md's "plain
/// text on disk" rule; `test_deletingTheWholeDesignDirectory_costsNoContentElsewhere`
/// pins it).
///
/// **Standalone, not a `ProjectStore` extension.** It owns one directory
/// tree and nothing else — no manifest, no structure, no id registry — so it
/// takes a bare `projectURL` the way `TrashStore`/`PublicationSnapshotStore`
/// do. It mints its own ids by calling `ProjectStore.newId(prefix:)` directly
/// (that helper is not `private`, and `ProjectFactory` — itself no
/// `ProjectStore` extension — already calls it the same way for `"doc"`
/// ids), rather than keeping a second copy of the same eight-hex-char
/// scheme. A caller that needs the designer's NAME resolves it separately
/// (`ProjectStore.designerRole()`, which never mints) and passes it into
/// `stage`, `TranslatorOrchestrator.IngestContext`'s shape: identity is
/// resolved once, upstream, and carried — never re-resolved by the store
/// that merely records it.
@MainActor
struct DesignProposalStore {

    enum StoreError: Error, Equatable, CustomStringConvertible {
        case notFound(id: String)
        /// `delete` refused: a promotion of this proposal stands, and its
        /// `backup/` is the only copy of the templates it displaced.
        case promotionBackupStands(id: String)

        var description: String {
            switch self {
            case .notFound(let id):
                return "no design proposal \(id)."
            case .promotionBackupStands(let id):
                return "\(id) is promoted and its backup holds the only copy of "
                    + "the templates it replaced — deleting it now would take "
                    + "your originals with it. Revert the promotion to put them "
                    + "back, or finalize it to keep this design and let them go."
            }
        }
    }

    /// `pending`/`approved`/`rejected`/`superseded` are every status this
    /// build writes. `.unknown(raw)` follows `PassState`'s discipline, not
    /// `SynthesisSource`'s (ADR 0015): a proposal isn't append-only like an
    /// `Op` — `updateStatus`/`recordSampleResult` REWRITE `proposal.json` in
    /// place — so a status a newer build wrote must round-trip through an
    /// older one unchanged, or touching any other field on that proposal
    /// (recording a sample result, say) would silently clobber a status this
    /// build can't represent down to the lossy literal `"unknown"`.
    enum Status: Codable, Equatable, Hashable, Sendable {
        case pending
        case approved
        case rejected
        case superseded
        /// A status written by a newer build. Carries the original raw
        /// string so re-encode is lossless (see type doc).
        case unknown(String)

        private static let pendingRaw = "pending"
        private static let approvedRaw = "approved"
        private static let rejectedRaw = "rejected"
        private static let supersededRaw = "superseded"

        var rawValue: String {
            switch self {
            case .pending: return Self.pendingRaw
            case .approved: return Self.approvedRaw
            case .rejected: return Self.rejectedRaw
            case .superseded: return Self.supersededRaw
            case .unknown(let raw): return raw
            }
        }

        init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            switch raw {
            case Self.pendingRaw: self = .pending
            case Self.approvedRaw: self = .approved
            case Self.rejectedRaw: self = .rejected
            case Self.supersededRaw: self = .superseded
            default: self = .unknown(raw)
            }
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(rawValue)
        }
    }

    /// Task 7's sample-compile outcome, recorded onto a proposal after
    /// staging (never by `stage` itself — a proposal exists, reviewable,
    /// before its sample compile has even started). The cause rides the
    /// result rather than being thrown away (RULING-7's shape): a tectonic
    /// failure is something the gate view shows beside the proposal, not a
    /// reason the proposal itself is unreadable.
    ///
    /// **`demonstrates` rides the pages for the same reason the cause rides
    /// the failure** (P4 Task 5). `SamplePageSelection` computes those
    /// writer-facing lines — *"chapter opener — ‘The Fog’"* — and
    /// `SampleCompiler.Outcome` carries them, but until this task
    /// `sampleResult(_:)` dropped them on the way to disk, so the one surface
    /// that exists to say *why these pages* had nothing to say it with. They
    /// cannot be recovered later: the selection is a pure function of the AST
    /// **as it stood at the round**, and the writer has been writing since.
    ///
    /// **Hand-written `Codable`, tolerant of the older shape.** The
    /// synthesized decoder would reject a `{"pages":{"path":…}}` written
    /// before this task, and by `Status`' own argument that is not a missing
    /// line on a gate — `readProposal` throws, `list()` skips the folder, and
    /// the writer's standing design round vanishes off the desk. The encoded
    /// shape is the synthesized one, so only the *reading* is widened.
    enum SampleResult: Codable, Equatable, Sendable {
        /// `fallbackPieces` is how many pieces in these pages were typeset from
        /// the BOOK's own text because the edition's translation was
        /// incomplete — a sample is compiled `allowStale` (see
        /// `SampleCompiler`), so this is the only record that pages a designer
        /// is about to approve are partly in the wrong language. Zero for every
        /// source round and every complete edition.
        case pages(path: String, demonstrates: [String], fallbackPieces: Int)
        case failed(error: String)

        private enum CodingKeys: String, CodingKey { case pages, failed }
        private enum PagesKeys: String, CodingKey {
            case path, demonstrates
            case fallbackPieces = "fallback_pieces"
        }
        private enum FailedKeys: String, CodingKey { case error }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            if container.contains(.pages) {
                let pages = try container.nestedContainer(
                    keyedBy: PagesKeys.self, forKey: .pages)
                // Additive (ADR 0015): a record written before the gate
                // could say so decodes as zero — "nothing known to have
                // fallen back" — rather than throwing.
                self = .pages(
                    path: try pages.decode(String.self, forKey: .path),
                    demonstrates: try pages.decodeIfPresent(
                        [String].self, forKey: .demonstrates) ?? [],
                    fallbackPieces: try pages.decodeIfPresent(
                        Int.self, forKey: .fallbackPieces) ?? 0)
                return
            }
            if container.contains(.failed) {
                let failed = try container.nestedContainer(
                    keyedBy: FailedKeys.self, forKey: .failed)
                self = .failed(error: try failed.decode(String.self, forKey: .error))
                return
            }
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "a sample result with neither arm present"))
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .pages(let path, let demonstrates, let fallbackPieces):
                var pages = container.nestedContainer(
                    keyedBy: PagesKeys.self, forKey: .pages)
                try pages.encode(path, forKey: .path)
                try pages.encode(demonstrates, forKey: .demonstrates)
                try pages.encode(fallbackPieces, forKey: .fallbackPieces)
            case .failed(let error):
                var failed = container.nestedContainer(
                    keyedBy: FailedKeys.self, forKey: .failed)
                try failed.encode(error, forKey: .error)
            }
        }
    }

    struct Proposal: Codable, Equatable {
        let id: String
        let designerName: String
        let round: Int
        /// The edition this round was briefed for, or `nil` for a round about
        /// the book itself — `DesignerOrchestrator.StageContext.language`,
        /// which reached `stage` from the first round and was the one fact
        /// about a round this store did not write down (P4 Task 5).
        ///
        /// **The gate cannot infer it.** Maugham keeps ONE template set per
        /// book, so an edition round proposes the book's own files and its
        /// staged list looks identical either way; what differs is that its
        /// sample pages set the *edition's* text in the *base* templates,
        /// which is the caveat the gate is required to make (P4 Global
        /// Constraint 3). Optional, so a proposal staged before this task
        /// decodes with no language — the honest answer for a round nobody
        /// recorded one for.
        let language: String?
        let created: Date
        var status: Status
        let specMarkdown: String
        /// Paths relative to this proposal's `files/` directory, staged
        /// verbatim from `DesignerReport.ProposedFile.path` — already
        /// safety-gated at parse (Task 3: relative, no traversal, no `~`, no
        /// `config.json`, case-folded-unique).
        let filePaths: [String]
        var sampleResult: SampleResult?
        /// Why this proposal was taken back, written by `ProposalPromotion`'s
        /// revert (Task 8) — the writer's own words when they gave any, and a
        /// standing sentence when they did not. Optional, and absent on every
        /// proposal that was never promoted: a `rejected` proposal with nothing
        /// to say is one the writer turned down on sight, which is a different
        /// story from one whose templates shipped and came back.
        var revertNote: String?
    }

    let projectURL: URL

    init(projectURL: URL) {
        self.projectURL = projectURL
    }

    var designDir: URL {
        projectURL.appendingPathComponent(".maugham/design", isDirectory: true)
    }

    var proposalsDir: URL {
        designDir.appendingPathComponent("proposals", isDirectory: true)
    }

    func proposalDir(id: String) -> URL {
        proposalsDir.appendingPathComponent(id, isDirectory: true)
    }

    /// Where `ProposalPromotion` holds the live templates a promotion of this
    /// proposal displaced. The path is spelled HERE, once, rather than in the
    /// promotion that writes it: this store owns the proposal directory's
    /// layout, and `delete` below has to know about the backup, because while
    /// one stands this directory is not merely derived.
    func backupDir(id: String) -> URL {
        proposalDir(id: id).appendingPathComponent("backup", isDirectory: true)
    }

    // MARK: - Staging

    /// Stage a finished designer report as a new `pending` proposal.
    ///
    /// **Supersedes first, mints second.** The desk carries one pending-
    /// proposal badge for the whole project (spec §5 — design has no
    /// per-language row the way translation does), so before anything is
    /// written, every proposal this store can see that is still `.pending`
    /// is rewritten `.superseded`. Never deleted: a superseded proposal is
    /// still a design round that happened, and stays in `list()`.
    ///
    /// **`language` is not defaulted** (P4 Task 5). It is the round's own
    /// identity, carried in on the same `StageContext` as `round` and
    /// `designerName`, and a default here is the argument that eventually gets
    /// left off by accident — after which an edition round is recorded as a
    /// round about the book and the gate approves it as one. Every caller says
    /// which it is.
    func stage(report: DesignerReport, round: Int, designerName: String,
               language: String?) throws -> Proposal {
        for var existing in try list() where existing.status == .pending {
            existing.status = .superseded
            try write(existing)
        }

        let id = ProjectStore.newId(prefix: "prop")
        let dir = proposalDir(id: id)
        let filesDir = dir.appendingPathComponent("files", isDirectory: true)
        let fm = FileManager.default
        try fm.createDirectory(at: filesDir, withIntermediateDirectories: true)

        try report.specMarkdown.write(
            to: dir.appendingPathComponent("spec.md"), atomically: true, encoding: .utf8)

        for file in report.files {
            let dest = filesDir.appendingPathComponent(file.path)
            try fm.createDirectory(
                at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            try file.content.write(to: dest, atomically: true, encoding: .utf8)
        }

        let proposal = Proposal(
            id: id, designerName: designerName, round: round, language: language,
            created: Date(), status: .pending, specMarkdown: report.specMarkdown,
            filePaths: report.files.map(\.path), sampleResult: nil, revertNote: nil)
        try write(proposal)
        return proposal
    }

    // MARK: - Reading

    /// Every staged proposal, newest first. Tolerant like `TrashStore.list()`:
    /// a folder this store cannot read `proposal.json` from is skipped
    /// rather than failing the whole listing.
    func list() throws -> [Proposal] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: proposalsDir.path) else { return [] }
        let folders = (try? fm.contentsOfDirectory(
            at: proposalsDir, includingPropertiesForKeys: nil, options: [])) ?? []
        var proposals: [Proposal] = []
        for folder in folders where folder.hasDirectoryPath {
            guard let proposal = try? readProposal(id: folder.lastPathComponent) else { continue }
            proposals.append(proposal)
        }
        return proposals.sorted { $0.created > $1.created }
    }

    func load(id: String) throws -> Proposal {
        try readProposal(id: id)
    }

    // MARK: - Status

    func updateStatus(id: String, _ status: Status) throws {
        var proposal = try readProposal(id: id)
        proposal.status = status
        try write(proposal)
    }

    /// Reject a proposal AND say why, in one write.
    ///
    /// Kept apart from `updateStatus` rather than given to it as an optional
    /// argument: a note belongs to exactly one status change — `ProposalPromotion`'s
    /// revert, the only place a proposal is turned down with something to
    /// explain — and every other caller would have to pass a `nil` that means
    /// "leave whatever is there", which is the argument that eventually gets
    /// passed by accident and erases a note.
    func reject(id: String, note: String) throws {
        var proposal = try readProposal(id: id)
        proposal.status = .rejected
        proposal.revertNote = note
        try write(proposal)
    }

    // MARK: - Sample result

    func sampleResult(id: String) throws -> SampleResult? {
        try readProposal(id: id).sampleResult
    }

    func recordSampleResult(id: String, _ result: SampleResult) throws {
        var proposal = try readProposal(id: id)
        proposal.sampleResult = result
        try write(proposal)
    }

    // MARK: - Delete

    /// Discard a proposal whole.
    ///
    /// **Refuses while a promotion of it stands.** Everything under
    /// `.maugham/design/` is derived — except for the window between `approve`
    /// and `revert`/`finalize`, when this proposal's `backup/` holds the only
    /// copy of the live templates it displaced. Deleting it then is not
    /// discarding a design round the writer did not want; it is destroying the
    /// templates they had before the round, with the new ones still shipping.
    /// The way out is `ProposalPromotion.revert` (take the promotion back) or
    /// `.finalize` (keep it, and let the originals go on purpose).
    func delete(id: String) throws {
        let dir = proposalDir(id: id)
        guard FileManager.default.fileExists(atPath: dir.path) else {
            throw StoreError.notFound(id: id)
        }
        guard !FileManager.default.fileExists(atPath: backupDir(id: id).path) else {
            throw StoreError.promotionBackupStands(id: id)
        }
        try FileManager.default.removeItem(at: dir)
    }

    // MARK: - private

    private func readProposal(id: String) throws -> Proposal {
        let url = proposalDir(id: id).appendingPathComponent("proposal.json")
        guard let data = try? Data(contentsOf: url)  // adr-0018-ok: design proposal metadata, not manuscript
        else { throw StoreError.notFound(id: id) }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Proposal.self, from: data)
    }

    private func write(_ proposal: Proposal) throws {
        let dir = proposalDir(id: proposal.id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(proposal).write(
            to: dir.appendingPathComponent("proposal.json"), options: .atomic)
    }
}
