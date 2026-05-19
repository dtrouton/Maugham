import Foundation

// MARK: - add_comment

public enum AddCommentTool {
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

    @MainActor
    public static func handle(
        paramsJSON: Data?, registry: ProjectRegistry
    ) async throws -> Data {
        let params = try decodeAnnotationParams(Params.self, from: paramsJSON,
            required: "project_id, document_id, paragraph_id, body required")
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

public enum AddSuggestedChangeTool {
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

    @MainActor
    public static func handle(
        paramsJSON: Data?, registry: ProjectRegistry
    ) async throws -> Data {
        let params = try decodeAnnotationParams(Params.self, from: paramsJSON,
            required: "project_id, document_id, paragraph_id, body, suggested_text required")
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

public enum AddQueryTool {
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

    @MainActor
    public static func handle(
        paramsJSON: Data?, registry: ProjectRegistry
    ) async throws -> Data {
        let params = try decodeAnnotationParams(Params.self, from: paramsJSON,
            required: "project_id, document_id, paragraph_id, body required")
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

public enum AddCraftNoteTool {
    public struct Params: Codable {
        public let project_id: String
        public let document_id: String
        public let body: String
    }
    public struct Result: Codable, Equatable {
        public let annotation_id: String
    }
    public static let method = "add_craft_note"

    @MainActor
    public static func handle(
        paramsJSON: Data?, registry: ProjectRegistry
    ) async throws -> Data {
        let params = try decodeAnnotationParams(Params.self, from: paramsJSON,
            required: "project_id, document_id, body required")
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

private func decodeAnnotationParams<T: Decodable>(
    _ type: T.Type, from data: Data?, required: String
) throws -> T {
    guard let data, let decoded = try? JSONDecoder().decode(T.self, from: data)
    else { throw MCPError.invalidArgument(required) }
    return decoded
}

private func annotationToolArgsJSON<T: Encodable>(_ params: T) -> String? {
    let enc = JSONEncoder()
    enc.outputFormatting = .sortedKeys
    return (try? enc.encode(params)).flatMap {
        String(data: $0, encoding: .utf8)
    }
}
