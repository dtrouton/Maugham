import Foundation
import MaughamCore

/// The staging half of "proposals into statements" (translation pipeline
/// spec §10; ADR 0030 §7). **Neither tool writes a statement.** Each validates
/// the draft, writes ONE slot under `.maugham/statements/proposals/` (a new
/// proposal supersedes the pending one for the same key), posts the
/// project-scoped changed event so the gate can draw, and returns where the
/// writer will find it. The write — if it ever happens — is the writer's
/// Adopt in `StatementPane`, through `StatementProposalGate`.
///
/// Mirrors `ReadEditionBriefTool` / `ReadVisualLanguageTool`'s shape: resolve
/// the project, project scope only, a language tag that is part of the slot's
/// identity is validated the way the read tool validates it.
enum StatementProposalTools {
    static let author = "Claude"

    /// Where the writer adopts it — one sentence the tool returns so a session
    /// can tell the writer, rather than guessing at a menu.
    static func adoptWhere(_ kind: ProposableStatement) -> String {
        switch kind {
        case .editionBrief(let language):
            return "In Maugham: Publish (⌘4) → Department desk (⌘⌥K) → the "
                + TranslationReviewIndicator.displayLabel(forLanguageTag: language)
                + " row's Edition Brief. A banner offers Adopt / Discard with a diff."
        case .visualLanguage:
            return "In Maugham: the Visual Language pane (⌘⌥V). A banner offers "
                + "Adopt / Discard with a diff against the current statement."
        }
    }

    @MainActor
    static func stage(kind: ProposableStatement, markdown: String, rationale: String?,
                      in store: ProjectStore) throws -> (StatementProposalStore.Proposal, superseded: Bool, glossary: Int) {
        let proposals = StatementProposalStore(projectURL: store.url)
        let superseded = proposals.pending(for: kind) != nil
        let proposal: StatementProposalStore.Proposal
        do {
            proposal = try proposals.stage(.init(
                kind: kind, markdown: markdown, rationale: rationale,
                proposedAt: Date(), author: author))
        } catch let refusal as StatementProposalStore.ProposalRefusal {
            throw MCPError.invalidArgument(refusal.description)
        }
        let glossary: Int
        if case .editionBrief = kind {
            glossary = (try? StatementProposalStore.glossaryLines(in: markdown).count) ?? 0
        } else {
            glossary = 0
        }
        MaughamEvent.postStatementProposalsChanged(projectURL: store.url)
        return (proposal, superseded, glossary)
    }
}

public enum ProposeEditionBriefTool: MCPTool {
    public static let method = "propose_edition_brief"
    public static let description =
        "Propose a draft edition brief for one language — the writer's doctrine for that "
        + "translated edition (register, forms of address, what a translator must not smooth, "
        + "typographic conventions) — as MARKDOWN the writer adopts or discards in Maugham. "
        + "This writes nothing: the draft is staged, and the writer sees it as a diff against "
        + "their current brief with Adopt / Discard. A `## Rulings` section may carry ONLY "
        + "glossary entries of the shape `- «term» → «rendering» (optional note)`; Adopt appends "
        + "them as rulings. Anything else under that heading is refused — directives and other "
        + "rulings are the writer's to make. A new proposal for the same language replaces the "
        + "pending one. Interview first (the `edition-brief` skill via get_help topic \"skills\"); "
        + "read read_craft_intent and read_edition_brief before drafting."
    public static let inputSchemaJSON =
        #"{"type":"object","properties":{"project_id":{"type":"string"},"language":{"type":"string","description":"lowercase tag, e.g. es, pt-br"},"markdown":{"type":"string","description":"the proposed brief, whole; optional ## Rulings section of glossary lines only"},"rationale":{"type":"string","description":"one or two sentences on why — shown to the writer beside the diff"}},"required":["project_id","language","markdown"]}"#

    public struct Params: Codable {
        public let project_id: String
        public let language: String
        public let markdown: String
        public let rationale: String?
    }
    public struct Result: Codable, Equatable {
        public let staged: Bool
        public let key: String
        public let supersededPending: Bool
        public let glossaryEntries: Int
        public let adoptWhere: String
    }

    @MainActor
    public static func handle(paramsJSON: Data?, registry: ProjectRegistry) async throws -> Data {
        let params = try decodeParams(Params.self, from: paramsJSON)
        guard TranslationRecord.isValidLanguageTag(params.language) else {
            throw MCPError.invalidArgument("invalid language tag: \(params.language)")
        }
        let entry = try resolveProject(params.project_id, in: registry)
        let kind = ProposableStatement.editionBrief(params.language)
        let (proposal, superseded, glossary) = try StatementProposalTools.stage(
            kind: kind, markdown: params.markdown, rationale: params.rationale, in: entry.store)
        return try JSONEncoder().encode(Result(
            staged: true, key: proposal.kind.key, supersededPending: superseded,
            glossaryEntries: glossary, adoptWhere: StatementProposalTools.adoptWhere(kind)))
    }
}

public enum ProposeVisualLanguageTool: MCPTool {
    public static let method = "propose_visual_language"
    public static let description =
        "Propose a draft visual language — the writer's freeform statement of how the book "
        + "should LOOK (trim, typeface feel, scale, rule weights, ornament, the idea behind "
        + "per-piece variation) — as MARKDOWN the writer adopts or discards in Maugham. This "
        + "writes nothing: the draft is staged, and the writer sees it as a diff against their "
        + "current statement in the Visual Language pane with Adopt / Discard. No `## Rulings` "
        + "section — a visual language has none. A new proposal replaces the pending one. "
        + "Interview first (the `visual-language` skill via get_help topic \"skills\"); read "
        + "read_visual_language and the sensory palette before drafting."
    public static let inputSchemaJSON =
        #"{"type":"object","properties":{"project_id":{"type":"string"},"markdown":{"type":"string","description":"the proposed statement, whole"},"rationale":{"type":"string","description":"one or two sentences on why — shown to the writer beside the diff"}},"required":["project_id","markdown"]}"#

    public struct Params: Codable {
        public let project_id: String
        public let markdown: String
        public let rationale: String?
    }
    public struct Result: Codable, Equatable {
        public let staged: Bool
        public let key: String
        public let supersededPending: Bool
        public let glossaryEntries: Int
        public let adoptWhere: String
    }

    @MainActor
    public static func handle(paramsJSON: Data?, registry: ProjectRegistry) async throws -> Data {
        let params = try decodeParams(Params.self, from: paramsJSON)
        let entry = try resolveProject(params.project_id, in: registry)
        let (proposal, superseded, _) = try StatementProposalTools.stage(
            kind: .visualLanguage, markdown: params.markdown, rationale: params.rationale, in: entry.store)
        return try JSONEncoder().encode(Result(
            staged: true, key: proposal.kind.key, supersededPending: superseded,
            glossaryEntries: 0, adoptWhere: StatementProposalTools.adoptWhere(.visualLanguage)))
    }
}
