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

    enum StoreError: Error, Equatable {
        case notFound(id: String)
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
    enum SampleResult: Codable, Equatable, Sendable {
        case pages(path: String)
        case failed(error: String)
    }

    struct Proposal: Codable, Equatable {
        let id: String
        let designerName: String
        let round: Int
        let created: Date
        var status: Status
        let specMarkdown: String
        /// Paths relative to this proposal's `files/` directory, staged
        /// verbatim from `DesignerReport.ProposedFile.path` — already
        /// safety-gated at parse (Task 3: relative, no traversal, no `~`, no
        /// `config.json`, case-folded-unique).
        let filePaths: [String]
        var sampleResult: SampleResult?
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

    // MARK: - Staging

    /// Stage a finished designer report as a new `pending` proposal.
    ///
    /// **Supersedes first, mints second.** The desk carries one pending-
    /// proposal badge for the whole project (spec §5 — design has no
    /// per-language row the way translation does), so before anything is
    /// written, every proposal this store can see that is still `.pending`
    /// is rewritten `.superseded`. Never deleted: a superseded proposal is
    /// still a design round that happened, and stays in `list()`.
    func stage(report: DesignerReport, round: Int, designerName: String) throws -> Proposal {
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
            id: id, designerName: designerName, round: round, created: Date(),
            status: .pending, specMarkdown: report.specMarkdown,
            filePaths: report.files.map(\.path), sampleResult: nil)
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

    func delete(id: String) throws {
        let dir = proposalDir(id: id)
        guard FileManager.default.fileExists(atPath: dir.path) else {
            throw StoreError.notFound(id: id)
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
