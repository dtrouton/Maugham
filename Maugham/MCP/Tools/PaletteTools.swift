import Foundation

/// list_palette_cards — summaries of the project's sensory-palette cards.
/// Full note text and images come from `read_palette_card` (a sibling tool
/// in this file); this one stays cheap for a project-wide overview.
public enum ListPaletteCardsTool: MCPTool {
    public static let method = "list_palette_cards"
    public static let description =
        "List the project's sensory-palette cards (subject-keyed reference material: "
        + "locations, characters, motifs — each with swatches, sensory notes, images). "
        + "Use read_palette_card for a card's full notes and images."
    public static let inputSchemaJSON =
        #"{"type":"object","properties":{"project_id":{"type":"string"}},"required":["project_id"]}"#

    public struct Params: Codable { public let project_id: String }
    public struct CardSummary: Codable, Equatable {
        public let id: String
        public let title: String
        public let kind: String
        public let swatches: [String]
        public let note_count: Int
        public let image_paths: [String]
    }
    public struct Result: Codable, Equatable { public let cards: [CardSummary] }

    @MainActor
    public static func handle(paramsJSON: Data?, registry: ProjectRegistry) async throws -> Data {
        let params = try decodeParams(Params.self, from: paramsJSON)
        let entry = try resolveProject(params.project_id, in: registry)
        let cards = entry.store.loadPaletteCards().map { card in
            CardSummary(
                id: card.researchItemId, title: card.title, kind: card.kind.rawValue,
                swatches: card.swatches, note_count: card.notes.count,
                image_paths: card.imagePaths)
        }
        return try JSONEncoder().encode(Result(cards: cards))
    }
}
