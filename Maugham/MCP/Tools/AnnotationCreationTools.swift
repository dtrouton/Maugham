import Foundation
import MaughamCore

// MARK: - add_comment

public enum AddCommentTool: MCPTool {
    public struct Params: Codable {
        public let project_id: String
        public let document_id: String
        public let paragraph_id: String
        public let body: String
        public let quote: String?
    }
    public struct Result: Codable, Equatable {
        public let annotation_id: String
    }
    public static let method = "add_comment"
    public static let description =
        "Attach an editorial comment to a manuscript paragraph. Comments do not " +
        "modify the manuscript; the user accepts or rejects them via the " +
        "Annotations pane. Reject reasoning is captured for future sessions. " +
        "Optionally pass `quote` (an exact phrase from the paragraph) to anchor " +
        "the comment to a sub-paragraph span; omit it to anchor the whole paragraph."
    public static let inputSchemaJSON =
        #"{"type":"object","properties":{"project_id":{"type":"string"},"document_id":{"type":"string"},"paragraph_id":{"type":"string"},"body":{"type":"string"},"quote":{"type":"string"}},"required":["project_id","document_id","paragraph_id","body"]}"#

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
            let span = try resolveSpanAnchor(
                quote: params.quote, paragraphId: params.paragraph_id, in: doc)
            return try await doc.addAnnotation(
                kind: .comment,
                paragraphId: params.paragraph_id,
                body: params.body,
                toolArgs: annotationToolArgsJSON(params),
                span: span,
                author: claudeAnnotationAuthor)
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
        public let quote: String?
    }
    public struct Result: Codable, Equatable {
        public let annotation_id: String
    }
    public static let method = "add_suggested_change"
    public static let description =
        "Propose a specific replacement. `body` is the editorial justification. " +
        "Two grains — match `suggested_text` to the grain you use: " +
        "(1) omit `quote` → `suggested_text` is the COMPLETE replacement " +
        "paragraph; (2) pass `quote` (an exact phrase from the paragraph) → " +
        "`suggested_text` replaces ONLY that quoted span, so it must contain " +
        "just the span's replacement — never the whole paragraph and never the " +
        "text surrounding the quote. The user accepts (applies the change) or " +
        "rejects (with reasoning)."
    public static let inputSchemaJSON =
        #"{"type":"object","properties":{"project_id":{"type":"string"},"document_id":{"type":"string"},"paragraph_id":{"type":"string"},"body":{"type":"string"},"suggested_text":{"type":"string"},"quote":{"type":"string"}},"required":["project_id","document_id","paragraph_id","body","suggested_text"]}"#

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
            let span = try resolveSpanAnchor(
                quote: params.quote, paragraphId: params.paragraph_id, in: doc)
            return try await doc.addAnnotation(
                kind: .suggestedChange,
                paragraphId: params.paragraph_id,
                body: params.body,
                suggestedText: params.suggested_text,
                toolArgs: annotationToolArgsJSON(params),
                span: span,
                author: claudeAnnotationAuthor)
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
        public let quote: String?
    }
    public struct Result: Codable, Equatable {
        public let annotation_id: String
    }
    public static let method = "add_query"
    public static let description =
        "Ask the writer a question about a paragraph (intent, ambiguity, " +
        "character motivation). The writer replies via the Annotations pane; " +
        "the reply is persisted in the annotation history. Optionally pass " +
        "`quote` (an exact phrase from the paragraph) to anchor the query to a " +
        "sub-paragraph span; omit it to anchor the whole paragraph."
    public static let inputSchemaJSON =
        #"{"type":"object","properties":{"project_id":{"type":"string"},"document_id":{"type":"string"},"paragraph_id":{"type":"string"},"body":{"type":"string"},"quote":{"type":"string"}},"required":["project_id","document_id","paragraph_id","body"]}"#

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
            let span = try resolveSpanAnchor(
                quote: params.quote, paragraphId: params.paragraph_id, in: doc)
            return try await doc.addAnnotation(
                kind: .query,
                paragraphId: params.paragraph_id,
                body: params.body,
                toolArgs: annotationToolArgsJSON(params),
                span: span,
                author: claudeAnnotationAuthor)
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
