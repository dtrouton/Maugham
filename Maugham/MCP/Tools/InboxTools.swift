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
                    created_at: iso.string(from: e.createdAt))
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
        return try JSONEncoder().encode(entry)
    }
}

/// `promote_inbox_entry(project_id, entry_id, title?, target_document_id?)` —
/// move a capture into research and mark it promoted. Non-destructive; mirrors
/// the InboxPane action. `target_document_id` scopes the created item to a
/// chapter or collection piece (spec 2026-07-07); omitted → shared research.
public enum PromoteInboxEntryTool: MCPTool {
    public struct Params: Codable {
        public let project_id: String
        public let entry_id: String
        public let title: String?
        public let target_document_id: String?
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
        "Optional target_document_id scopes it to a chapter or collection " +
        "piece: piece → its research folder; novel chapter → shared research " +
        "plus a research link. Unknown ids fail."
    public static let inputSchemaJSON =
        #"{"type":"object","properties":{"project_id":{"type":"string"},"entry_id":{"type":"string"},"title":{"type":"string"},"target_document_id":{"type":"string"}},"required":["project_id","entry_id"]}"#

    @MainActor
    public static func handle(paramsJSON: Data?, registry: ProjectRegistry) async throws -> Data {
        let params = try decodeParams(Params.self, from: paramsJSON)
        let (store, inbox) = try liveInbox(registry, projectId: params.project_id)
        await inbox.refresh()
        guard var entry = inbox.entries.first(where: { $0.id == params.entry_id }) else {
            throw MCPError.invalidArgument(
                "inbox entry not found or already resolved: \(params.entry_id)")
        }
        if let title = params.title, !title.isEmpty { entry.title = title }
        let scope: ResearchScope =
            params.target_document_id.map { .document($0) } ?? .shared
        let created = try await inbox.promoteToResearch(
            entry, projectStore: store, scope: scope)
        return try JSONEncoder().encode(Result(
            research_id: created.id, title: created.title, path: created.path ?? ""))
    }
}
