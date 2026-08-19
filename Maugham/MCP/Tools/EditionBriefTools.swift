import Foundation
import MaughamCore

/// read_edition_brief — the publish department's doctrine for one language,
/// read by Claude before translating into it. **Mirrors
/// `Tools/VisualLanguageTools.swift`'s shape**: resolve the project entry,
/// look the statement up through `StatementLookup` via `entry.store`, derive
/// its text through `statementText(of:)`, and treat absence as a valid
/// non-error answer — never a reason to mint the file.
///
/// An edition brief holds the writer's register and idiom policy for one
/// language, plus whatever rulings a translation session has settled there
/// (`RulingPerformer` can write into `## Rulings`, `StatementEssay.carriesRulings`
/// says so) — so an answer to a translation question may already be sitting
/// in the brief rather than something to ask about again.
///
/// **Project scope only, and the schema says so by taking nothing else.**
/// `StatementConvention.newPath` has no row for `(.editionBrief, .document)`
/// — an edition's register applies to the whole book, not one chapter — so
/// this tool takes `project_id` and `language`, never an `item_id`.
///
/// ABSENCE IS VALID: returns `{exists: false, markdown: ""}`, never an error,
/// and mints nothing on the way — `read_craft_intent`'s shape, for the same
/// reason: a read that created the file would put a statement in the
/// project the writer never opened.
public enum ReadEditionBriefTool: MCPTool {
    public static let method = "read_edition_brief"
    public static let description =
        "Read the project's edition brief for one language — the writer's doctrine "
        + "for that translated edition: register, idiom policy, and any rulings settled "
        + "during earlier translation sessions. Read this before translating into a "
        + "language, and let it decide register/idiom rather than choosing on your own; "
        + "an answer to a translation question may already be a ruling recorded here. "
        + "Project scope only — an edition's register applies to the whole book, not one "
        + "chapter. Returns exists:false with empty markdown when the writer has not "
        + "declared a brief for that language yet; that is a valid, deliberate state, not "
        + "an error — a brief can be created in Maugham, not invented on the writer's behalf."
    public static let inputSchemaJSON =
        #"{"type":"object","properties":{"project_id":{"type":"string"},"language":{"type":"string","description":"lowercase tag, e.g. es, pt-br"}},"required":["project_id","language"]}"#

    public struct Params: Codable {
        public let project_id: String
        public let language: String
    }
    public struct Result: Codable, Equatable {
        public let exists: Bool
        public let markdown: String
        public let language: String
    }

    @MainActor
    public static func handle(paramsJSON: Data?, registry: ProjectRegistry) async throws -> Data {
        let params = try decodeParams(Params.self, from: paramsJSON)
        // Same refusal as the sibling translation tools (`TranslationTools.swift`):
        // a language tag is part of a statement's identity (`.editionBrief(tag)`),
        // and an uppercase or malformed tag would silently miss the brief a
        // lowercase-tagged write session already created.
        guard TranslationRecord.isValidLanguageTag(params.language) else {
            throw MCPError.invalidArgument("invalid language tag: \(params.language)")
        }
        let entry = try resolveProject(params.project_id, in: registry)
        guard let statement = entry.store.statement(
            kind: .editionBrief(params.language), scope: .project
        ) else {
            // Absence, not an error. Nothing is minted on the way — a read
            // that created the file would put a statement in the project the
            // writer never opened, for a language they may not even be
            // publishing.
            return try JSONEncoder().encode(
                Result(exists: false, markdown: "", language: params.language))
        }
        // Derived, never the `.md` (tripwire 20): `statementText` owns both
        // of ADR 0018's branches and is shared with `read_craft_intent` and
        // `read_visual_language`, so no reader of a statement can disagree
        // with another about which text is real.
        let markdown = try entry.store.statementText(of: statement)
        return try MCPResponseBudget.enforce(
            try JSONEncoder().encode(Result(exists: true, markdown: markdown, language: params.language)),
            hint: "The edition brief is too large to return in one MCP response. "
                + "Open it directly on disk at \(statement.path).")
    }
}
