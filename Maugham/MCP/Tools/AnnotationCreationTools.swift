import Foundation

// MARK: - add_comment

public enum AddCommentTool: MCPTool {
    public struct Params: Codable {
        public let project_id: String
        public let document_id: String
        public let paragraph_id: String
        public let body: String
    }
    public struct Result: Codable, Equatable {
        public let annotation_id: String
    }
    public static let method = "add_comment"
    public static let description =
        "Attach an editorial comment to a manuscript paragraph. Comments do not " +
        "modify the manuscript; the user accepts or rejects them via the " +
        "Annotations pane. Reject reasoning is captured for future sessions."
    public static let inputSchemaJSON =
        #"{"type":"object","properties":{"project_id":{"type":"string"},"document_id":{"type":"string"},"paragraph_id":{"type":"string"},"body":{"type":"string"}},"required":["project_id","document_id","paragraph_id","body"]}"#

    @MainActor
    public static func handle(
        paramsJSON: Data?, registry: ProjectRegistry
    ) async throws -> Data {
        let params = try decodeParams(Params.self, from: paramsJSON)
        let id = try await withAnnotationDocument(
            projectId: params.project_id,
            documentId: params.document_id,
            registry: registry
        ) { doc in
            try await doc.addAnnotation(
                kind: .comment,
                paragraphId: params.paragraph_id,
                body: params.body,
                toolArgs: annotationToolArgsJSON(params))
        }
        return try JSONEncoder().encode(Result(annotation_id: id))
    }
}

// MARK: - add_suggested_change

public enum AddSuggestedChangeTool: MCPTool {
    public struct Params: Codable {
        public let project_id: String
        public let document_id: String
        public let paragraph_id: String
        public let body: String
        public let suggested_text: String
    }
    public struct Result: Codable, Equatable {
        public let annotation_id: String
    }
    public static let method = "add_suggested_change"
    public static let description =
        "Propose a specific replacement for a paragraph. `body` is the editorial " +
        "justification; `suggested_text` is the proposed new paragraph. The user " +
        "accepts (applies the change) or rejects (with reasoning)."
    public static let inputSchemaJSON =
        #"{"type":"object","properties":{"project_id":{"type":"string"},"document_id":{"type":"string"},"paragraph_id":{"type":"string"},"body":{"type":"string"},"suggested_text":{"type":"string"}},"required":["project_id","document_id","paragraph_id","body","suggested_text"]}"#

    @MainActor
    public static func handle(
        paramsJSON: Data?, registry: ProjectRegistry
    ) async throws -> Data {
        let params = try decodeParams(Params.self, from: paramsJSON)
        let id = try await withAnnotationDocument(
            projectId: params.project_id,
            documentId: params.document_id,
            registry: registry
        ) { doc in
            try await doc.addAnnotation(
                kind: .suggestedChange,
                paragraphId: params.paragraph_id,
                body: params.body,
                suggestedText: params.suggested_text,
                toolArgs: annotationToolArgsJSON(params))
        }
        return try JSONEncoder().encode(Result(annotation_id: id))
    }
}

// MARK: - add_query

public enum AddQueryTool: MCPTool {
    public struct Params: Codable {
        public let project_id: String
        public let document_id: String
        public let paragraph_id: String
        public let body: String
    }
    public struct Result: Codable, Equatable {
        public let annotation_id: String
    }
    public static let method = "add_query"
    public static let description =
        "Ask the writer a question about a paragraph (intent, ambiguity, " +
        "character motivation). The writer replies via the Annotations pane; " +
        "the reply is persisted in the annotation history."
    public static let inputSchemaJSON =
        #"{"type":"object","properties":{"project_id":{"type":"string"},"document_id":{"type":"string"},"paragraph_id":{"type":"string"},"body":{"type":"string"}},"required":["project_id","document_id","paragraph_id","body"]}"#

    @MainActor
    public static func handle(
        paramsJSON: Data?, registry: ProjectRegistry
    ) async throws -> Data {
        let params = try decodeParams(Params.self, from: paramsJSON)
        let id = try await withAnnotationDocument(
            projectId: params.project_id,
            documentId: params.document_id,
            registry: registry
        ) { doc in
            try await doc.addAnnotation(
                kind: .query,
                paragraphId: params.paragraph_id,
                body: params.body,
                toolArgs: annotationToolArgsJSON(params))
        }
        return try JSONEncoder().encode(Result(annotation_id: id))
    }
}

// MARK: - add_craft_note

public enum AddCraftNoteTool: MCPTool {
    public struct Params: Codable {
        public let project_id: String
        public let document_id: String
        public let body: String
    }
    public struct Result: Codable, Equatable {
        public let annotation_id: String
    }
    public static let method = "add_craft_note"
    public static let description =
        "Record a document-scoped craft observation (e.g., character voice rule, " +
        "structural pattern). Doc-scoped; no paragraph anchor. Accepted craft " +
        "notes surface in `list_annotations(kind: craft_note, status: accepted)` " +
        "for next-session reference."
    public static let inputSchemaJSON =
        #"{"type":"object","properties":{"project_id":{"type":"string"},"document_id":{"type":"string"},"body":{"type":"string"}},"required":["project_id","document_id","body"]}"#

    @MainActor
    public static func handle(
        paramsJSON: Data?, registry: ProjectRegistry
    ) async throws -> Data {
        let params = try decodeParams(Params.self, from: paramsJSON)
        let id = try await withAnnotationDocument(
            projectId: params.project_id,
            documentId: params.document_id,
            registry: registry
        ) { doc in
            try await doc.addAnnotation(
                kind: .craftNote,
                paragraphId: nil,
                body: params.body,
                toolArgs: annotationToolArgsJSON(params))
        }
        return try JSONEncoder().encode(Result(annotation_id: id))
    }
}

// MARK: - File-private helpers

private func annotationToolArgsJSON<T: Encodable>(_ params: T) -> String? {
    let enc = JSONEncoder()
    enc.outputFormatting = .sortedKeys
    return (try? enc.encode(params)).flatMap {
        String(data: $0, encoding: .utf8)
    }
}
