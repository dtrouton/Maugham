import Foundation
import MaughamCore

// MCP surface for the capture inbox (`.maugham/inbox/`). Scope decided
// 2026-05-29: **read + promote** only — no add, no trash. Promote is
// non-destructive (moves an asset into research/, recoverable) and matches
// Claude's existing research-librarian role; add/trash were excluded to avoid
// muddying the inbox's "writer's off-desk capture" identity and to keep
// destructive triage decisions writer-only. See spec §3.x / ADR 0004.
//
// All three resolve the *live* per-window InboxStore via
// `store.documentStore?.inboxStore`, so the InboxPane refreshes automatically
// after a promote (the store is @Observable and the pane observes it).

@MainActor
private func liveInbox(_ registry: ProjectRegistry, projectId: String) throws
    -> (store: ProjectStore, inbox: InboxStore) {
    guard let entry = registry.lookup(id: projectId) else { throw MCPError.unknownProjectID(projectId) }
    guard let inbox = entry.store.documentStore?.inboxStore else {
        throw MCPError.invalidArgument("inbox unavailable for project: \(projectId)")
    }
    return (entry.store, inbox)
}

/// `list_inbox(project_id)` — summarize the project's open (`.new`) captures.
public enum ListInboxTool: MCPTool {
    public struct Params: Codable { public let project_id: String }
    public struct Summary: Codable, Equatable {
        public let id: String
        public let kind: String
        public let title: String?
        public let transcript: String?
        public let inline_text: String?
        public let transcription_state: String
        public let created_at: String
        public let palette_subject: String?
        public let sense: String?
    }
    public struct Result: Codable, Equatable { public let entries: [Summary] }

    public static let method = "list_inbox"
    public static let description =
        "List the project's open inbox captures (text, photo, voice) awaiting " +
        "triage. Read-only."
    public static let inputSchemaJSON =
        #"{"type":"object","properties":{"project_id":{"type":"string"}},"required":["project_id"]}"#

    @MainActor
    public static func handle(paramsJSON: Data?, registry: ProjectRegistry) async throws -> Data {
        let params = try decodeParams(Params.self, from: paramsJSON)
        let (_, inbox) = try liveInbox(registry, projectId: params.project_id)
        await inbox.refresh()
        let iso = ISO8601DateFormatter()
        let summaries = inbox.entries.map { e in
            Summary(id: e.id, kind: e.kind.rawValue, title: e.title,
                    transcript: e.transcript, inline_text: e.inlineText,
                    transcription_state: e.transcriptionState.rawValue,
                    created_at: iso.string(from: e.createdAt),
                    palette_subject: e.paletteSubject, sense: e.sense)
        }
        return try JSONEncoder().encode(Result(entries: summaries))
    }
}

/// `read_inbox_entry(project_id, entry_id)` — full detail for one capture.
public enum ReadInboxEntryTool: MCPTool {
    public struct Params: Codable { public let project_id: String; public let entry_id: String }

    public static let method = "read_inbox_entry"
    public static let description =
        "Read a single inbox capture's full detail (text or transcript, kind, " +
        "asset filename). Read-only."
    public static let inputSchemaJSON =
        #"{"type":"object","properties":{"project_id":{"type":"string"},"entry_id":{"type":"string"}},"required":["project_id","entry_id"]}"#

    @MainActor
    public static func handle(paramsJSON: Data?, registry: ProjectRegistry) async throws -> Data {
        let params = try decodeParams(Params.self, from: paramsJSON)
        let (_, inbox) = try liveInbox(registry, projectId: params.project_id)
        await inbox.refresh()
        guard let entry = inbox.entries.first(where: { $0.id == params.entry_id }) else {
            // Fail loudly on unknown/resolved id (the namespace-footgun lesson).
            throw MCPError.invalidArgument(
                "inbox entry not found or already resolved: \(params.entry_id)")
        }
        return try MCPResponseBudget.enforce(
            try JSONEncoder().encode(entry),
            hint: "This capture (likely a long voice transcript) is too large to "
                + "return in one MCP response. Read the source asset directly on "
                + "disk under .maugham/inbox/.")
    }
}

/// `promote_inbox_entry(project_id, entry_id, title?, target_document_id?, palette_card_id?, palette_subject?)`
/// — move a capture into research (or an existing sensory-palette card) and
/// mark it promoted. Non-destructive; mirrors the InboxPane action.
/// `target_document_id`, `palette_card_id`, and `palette_subject` are three
/// alternative destinations — at most one may be set; omitting all three
/// promotes to shared research (the legacy behavior). Palette promotes reuse
/// the research Result shape: `research_id` is the card's id, `path` its
/// markdown file path.
public enum PromoteInboxEntryTool: MCPTool {
    public struct Params: Codable {
        public let project_id: String
        public let entry_id: String
        public let title: String?
        public let target_document_id: String?
        public let palette_card_id: String?
        public let palette_subject: String?
    }
    public struct Result: Codable, Equatable {
        public let research_id: String
        public let title: String
        public let path: String
    }

    public static let method = "promote_inbox_entry"
    public static let description =
        "Move an inbox capture into the project's research and mark it " +
        "promoted. Non-destructive (the capture becomes a research item). " +
        "Three alternative, mutually exclusive destinations — at most one: " +
        "target_document_id scopes it to a chapter or collection piece " +
        "(piece → its research folder; novel chapter → shared research plus " +
        "a research link); palette_card_id lands it as a sensory note (or " +
        "image) on an existing palette card by id; palette_subject does the " +
        "same by case-insensitive card title match (no match fails, listing " +
        "existing titles — this tool never mints a new card; create one in " +
        "the Palette pane first). Omitting all three promotes to shared " +
        "research. title is honored for research promotes only (the default " +
        "and target_document_id paths); palette-card promotes ignore it — " +
        "the card keeps its own title. Palette promotes reuse the research " +
        "Result shape (research_id is the card id, path its markdown file). " +
        "Unknown ids fail."
    public static let inputSchemaJSON =
        #"{"type":"object","properties":{"project_id":{"type":"string"},"entry_id":{"type":"string"},"title":{"type":"string"},"target_document_id":{"type":"string"},"palette_card_id":{"type":"string"},"palette_subject":{"type":"string"}},"required":["project_id","entry_id"]}"#

    @MainActor
    public static func handle(paramsJSON: Data?, registry: ProjectRegistry) async throws -> Data {
        let params = try decodeParams(Params.self, from: paramsJSON)
        try validateDestinationExclusivity(params)
        let (store, inbox) = try liveInbox(registry, projectId: params.project_id)
        await inbox.refresh()
        guard var entry = inbox.entries.first(where: { $0.id == params.entry_id }) else {
            throw MCPError.invalidArgument(
                "inbox entry not found or already resolved: \(params.entry_id)")
        }
        if let title = params.title, !title.isEmpty { entry.title = title }

        if let cardId = nonEmpty(params.palette_card_id) {
            return try await promoteToPalette(entry, cardId: cardId, store: store, inbox: inbox)
        }
        if let subject = nonEmpty(params.palette_subject) {
            let cardId = try resolveCardId(bySubject: subject, in: store)
            return try await promoteToPalette(entry, cardId: cardId, store: store, inbox: inbox)
        }

        let scope: ResearchScope =
            params.target_document_id.map { .document($0) } ?? .shared
        let created = try await inbox.promoteToResearch(
            entry, projectStore: store, scope: scope)
        return try JSONEncoder().encode(Result(
            research_id: created.id, title: created.title, path: created.path ?? ""))
    }

    /// At most one of the three destination params may be set — a caller
    /// specifying two (e.g. `palette_card_id` + `target_document_id`) named
    /// a genuine ambiguity, not a preference order to arbitrate silently.
    private static func validateDestinationExclusivity(_ params: Params) throws {
        let destinations: [(name: String, value: String?)] = [
            ("target_document_id", nonEmpty(params.target_document_id)),
            ("palette_card_id", nonEmpty(params.palette_card_id)),
            ("palette_subject", nonEmpty(params.palette_subject)),
        ]
        let set = destinations.filter { $0.value != nil }.map(\.name)
        guard set.count > 1 else { return }
        throw MCPError.invalidArgument(
            "\(set.joined(separator: " and ")) are mutually exclusive — " +
            "specify at most one promote destination")
    }

    /// Case-insensitive title match over the project's existing palette
    /// cards. No match fails loudly, listing existing titles, rather than
    /// minting a card — card creation stays a writer decision in the UI.
    @MainActor
    private static func resolveCardId(bySubject subject: String, in store: ProjectStore) throws -> String {
        let items = store.paletteCardItems()
        if let match = items.first(where: { $0.title.caseInsensitiveCompare(subject) == .orderedSame }) {
            return match.id
        }
        let titles = items.map(\.title)
        let list = titles.isEmpty ? "(none)" : titles.joined(separator: ", ")
        throw MCPError.invalidArgument(
            "no palette card titled '\(subject)' — existing palette cards: \(list)")
    }

    @MainActor
    private static func promoteToPalette(
        _ entry: InboxEntry, cardId: String, store: ProjectStore, inbox: InboxStore
    ) async throws -> Data {
        let card = try await inbox.promoteToPaletteCard(entry, projectStore: store, cardId: cardId)
        let path = store.paletteCardItems().first(where: { $0.id == card.id })?.path ?? ""
        return try JSONEncoder().encode(Result(research_id: card.id, title: card.title, path: path))
    }

    private static func nonEmpty(_ s: String?) -> String? {
        guard let s, !s.isEmpty else { return nil }
        return s
    }
}
