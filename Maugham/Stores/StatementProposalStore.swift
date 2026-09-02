import Foundation
import MaughamCore

/// Which statements Claude may PROPOSE a draft of (translation pipeline spec
/// §10). Two cases, on purpose: craft intent is the writer's own yardstick
/// (ADR 0028 §3) and is unrepresentable here rather than refused at runtime —
/// there is no case to reach it with.
enum ProposableStatement: Equatable, Hashable, Codable, Sendable {
    case editionBrief(String)
    case visualLanguage

    /// The statement this proposal is about. Total: both cases have a kind.
    var statementKind: Statement.Kind {
        switch self {
        case .editionBrief(let language): return .editionBrief(language.lowercased())
        case .visualLanguage: return .visualLanguage
        }
    }

    /// The reverse map. `nil` for a kind nothing may propose — intent, and a
    /// newer build's `.unknown`.
    init?(kind: Statement.Kind) {
        switch kind {
        case .editionBrief(let language): self = .editionBrief(language.lowercased())
        case .visualLanguage: self = .visualLanguage
        case .intent, .unknown: return nil
        }
    }

    /// The slot's filename stem. Lowercased so `ES` and `es` are one slot;
    /// hyphenated so no `:` reaches a filename.
    var key: String {
        switch self {
        case .editionBrief(let language): return "edition-brief-" + language.lowercased()
        case .visualLanguage: return "visual-language"
        }
    }

    /// What the banner calls it: "Spanish edition brief", "visual language".
    var displayName: String {
        switch self {
        case .editionBrief(let language):
            return TranslationReviewIndicator.displayLabel(forLanguageTag: language) + " edition brief"
        case .visualLanguage: return "visual language"
        }
    }
}

/// Where a proposed brief or visual language waits for the writer's verdict:
/// `.maugham/statements/proposals/<key>.json`, one pending slot per key.
///
/// **Everything here is DERIVED.** A proposal is a draft Claude can make
/// again; deleting `.maugham/statements/` costs that and never a word the
/// writer wrote. Standalone over a bare `projectURL`, `DesignProposalStore`'s
/// shape. It never writes a statement — `StatementProposalGate.adopt` is the
/// one place a proposal's words reach one, and it is a writer's click.
@MainActor
struct StatementProposalStore {

    struct Proposal: Codable, Equatable, Sendable {
        let kind: ProposableStatement
        let markdown: String
        let rationale: String?
        let proposedAt: Date
        let author: String
    }

    enum ProposalRefusal: Error, Equatable, CustomStringConvertible {
        case emptyMarkdown
        case rulingsNotGlossary(line: String)
        case emptyGlossaryTerm(line: String)
        case visualLanguageCarriesRulings
        case invalidLanguageTag(String)

        var description: String {
            switch self {
            case .emptyMarkdown:
                return "A proposal needs some text."
            case .rulingsNotGlossary(let line):
                return "Under ## Rulings a proposal may carry only glossary entries — "
                    + "«term» → «rendering» (optional note). A directive or any other ruling "
                    + "is the writer's to make. Refused: “\(line)”."
            case .emptyGlossaryTerm(let line):
                return "A glossary entry needs both a term and a rendering. Refused: “\(line)”."
            case .visualLanguageCarriesRulings:
                return "A visual language has no rulings section; put everything in the prose."
            case .invalidLanguageTag(let tag):
                return "invalid language tag: \(tag)"
            }
        }
    }

    let projectURL: URL
    init(projectURL: URL) { self.projectURL = projectURL }

    static func directoryURL(in projectURL: URL) -> URL {
        projectURL.appendingPathComponent(".maugham/statements/proposals", isDirectory: true)
    }
    static func fileURL(key: String, in projectURL: URL) -> URL {
        directoryURL(in: projectURL).appendingPathComponent(key + ".json")
    }

    // MARK: - Validation

    /// The glossary rows a proposal carries under `## Rulings`, or a refusal
    /// naming the first line that is not one. Parsed with the SAME parser the
    /// brief is read back with (`RulingsSection.parse` + `Ruling.glossary`),
    /// so what is accepted here is exactly what the table will draw.
    static func glossaryLines(in markdown: String) throws(ProposalRefusal)
        -> [(term: String, rendering: String, note: String?)] {
        var rows: [(term: String, rendering: String, note: String?)] = []
        for ruling in RulingsSection.parse(markdown).rulings {
            guard let entry = ruling.glossary else {
                throw .rulingsNotGlossary(line: ruling.text)
            }
            let term = entry.term.trimmingCharacters(in: .whitespaces)
            let rendering = entry.rendering.trimmingCharacters(in: .whitespaces)
            guard !term.isEmpty, !rendering.isEmpty else {
                throw .emptyGlossaryTerm(line: ruling.text)
            }
            rows.append((term, rendering, entry.note))
        }
        return rows
    }

    static func validate(kind: ProposableStatement, markdown: String) throws(ProposalRefusal) {
        guard !markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw .emptyMarkdown
        }
        switch kind {
        case .editionBrief(let language):
            guard TranslationRecord.isValidLanguageTag(language) else {
                throw .invalidLanguageTag(language)
            }
            _ = try glossaryLines(in: markdown)
        case .visualLanguage:
            guard RulingsSection.parse(markdown).rulings.isEmpty else {
                throw .visualLanguageCarriesRulings
            }
        }
    }

    // MARK: - The slot

    func pending(for kind: ProposableStatement) -> Proposal? {
        read(key: kind.key)
    }

    /// Every pending proposal, oldest first. Tolerant: an unreadable slot is
    /// skipped, never a crash and never a thrown listing.
    func pendingAll() -> [Proposal] {
        let dir = Self.directoryURL(in: projectURL)
        let files = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil, options: [])) ?? []
        return files
            .filter { $0.pathExtension == "json" }
            .compactMap { read(key: $0.deletingPathExtension().lastPathComponent) }
            .sorted { $0.proposedAt < $1.proposedAt }
    }

    /// Validate, then overwrite the slot: a new proposal supersedes.
    @discardableResult
    func stage(_ proposal: Proposal) throws -> Proposal {
        try Self.validate(kind: proposal.kind, markdown: proposal.markdown)
        let dir = Self.directoryURL(in: projectURL)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        // Deliberately NOT `.iso8601` (unlike `DesignProposalStore`'s
        // `proposal.json`, which nothing compares for exact equality):
        // ISO8601's default formatting truncates to whole seconds, so a
        // proposal read back would never `==` the in-memory one `stage`
        // returns. The default strategy round-trips `Date` exactly (a
        // `Double`, JSON-number-exact both ways).
        try encoder.encode(proposal).write(
            to: Self.fileURL(key: proposal.kind.key, in: projectURL), options: .atomic)
        return proposal
    }

    /// Clear the slot. An empty slot is not an error — Discard after a
    /// supersede that already emptied it must not go red.
    func discard(_ kind: ProposableStatement) throws {
        let url = Self.fileURL(key: kind.key, in: projectURL)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    // MARK: - private

    private func read(key: String) -> Proposal? {
        let url = Self.fileURL(key: key, in: projectURL)
        guard let data = try? Data(contentsOf: url) else { return nil }  // adr-0018-ok: statement proposal, derived sidecar
        let decoder = JSONDecoder()
        return try? decoder.decode(Proposal.self, from: data)
    }
}
