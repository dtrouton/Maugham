import Foundation
import MaughamCore

// MARK: - add_comment

public enum AddCommentTool: MCPTool {
    public struct Params: Codable {
        public let project_id: String
        public let document_id: String?
        public let paragraph_id: String?
        public let figure: String?
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
        "the comment to a sub-paragraph span; omit it to anchor the whole paragraph. " +
        "Running an editing pass? Call get_help with topic \"editing-pass\" first — " +
        "it covers craft intent and annotation conventions. " +
        "To comment on a table figure instead, pass `figure` (tbl:name for the whole " +
        "figure, tbl:name!C3 for a cell, tbl:name!C3:E3 for a range) and omit " +
        "`document_id`, `paragraph_id` and `quote`."
    public static let inputSchemaJSON =
        #"{"type":"object","properties":{"project_id":{"type":"string"},"document_id":{"type":"string"},"paragraph_id":{"type":"string"},"figure":{"type":"string","description":"a table figure instead of a paragraph: tbl:name, tbl:name!C3 or tbl:name!C3:E3"},"body":{"type":"string"},"quote":{"type":"string"}},"required":["project_id","body"]}"#

    @MainActor
    public static func handle(
        paramsJSON: Data?, registry: ProjectRegistry
    ) async throws -> Data {
        let params = try decodeParams(Params.self, from: paramsJSON)
        let target = try AnnotationTarget.resolve(
            figure: params.figure, documentId: params.document_id, paragraphId: params.paragraph_id)
        guard case .paragraph(let documentId, let paragraphId) = target else {
            guard params.quote == nil else {
                throw MCPError.invalidArgument("`quote` anchors text in a paragraph; a figure note has none.")
            }
            let id = try await addFigureNote(
                kind: .comment, projectId: params.project_id, figure: params.figure ?? "",
                body: params.body, registry: registry)
            return try JSONEncoder().encode(Result(annotation_id: id))
        }
        // The pass the writer is working this piece through, resolved before
        // the document is opened so the two arms of `withAnnotationDocument`
        // cannot disagree about it (see `activeReviewPassId`).
        let activePass = activeReviewPassId(
            projectId: params.project_id, documentId: documentId,
            registry: registry)
        let id = try await withAnnotationDocument(
            projectId: params.project_id,
            documentId: documentId,
            registry: registry
        ) { doc in
            let span = try resolveSpanAnchor(
                quote: params.quote, paragraphId: paragraphId, in: doc)
            return try await doc.addAnnotation(
                kind: .comment,
                paragraphId: paragraphId,
                body: params.body,
                toolArgs: annotationToolArgsJSON(params),
                span: span,
                author: claudeAnnotationAuthor,
                reviewPassId: activePass)
        }
        return try JSONEncoder().encode(Result(annotation_id: id))
    }
}

// MARK: - add_suggested_change

public enum AddSuggestedChangeTool: MCPTool {
    public struct Params: Codable {
        public let project_id: String
        public let document_id: String?
        public let paragraph_id: String?
        public let figure: String?
        public let body: String
        public let suggested_text: String?
        public let suggested_value: String?
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
        "rejects (with reasoning). To propose a value for ONE table cell, pass " +
        "`figure` (tbl:name!C3) and `suggested_value` instead of the paragraph " +
        "fields: a number with `.` for the decimal and no grouping (1234.5), text, " +
        "or a formula starting `=` with A1 references by the cell positions " +
        "read_figure shows; empty proposes clearing the cell. The author accepts " +
        "it in the grid; the cell is never written for you."
    public static let inputSchemaJSON =
        #"{"type":"object","properties":{"project_id":{"type":"string"},"document_id":{"type":"string"},"paragraph_id":{"type":"string"},"figure":{"type":"string","description":"a table figure instead of a paragraph: tbl:name, tbl:name!C3 or tbl:name!C3:E3"},"body":{"type":"string"},"suggested_text":{"type":"string"},"suggested_value":{"type":"string","description":"with `figure`: the proposed cell, in machine form"},"quote":{"type":"string"}},"required":["project_id","body"]}"#

    @MainActor
    public static func handle(
        paramsJSON: Data?, registry: ProjectRegistry
    ) async throws -> Data {
        let params = try decodeParams(Params.self, from: paramsJSON)
        let target = try AnnotationTarget.resolve(
            figure: params.figure, documentId: params.document_id, paragraphId: params.paragraph_id)
        guard case .paragraph(let documentId, let paragraphId) = target else {
            guard params.quote == nil, params.suggested_text == nil else {
                throw MCPError.invalidArgument(
                    "A figure suggestion takes `suggested_value`, not `quote` or `suggested_text`.")
            }
            let id = try await addFigureNote(
                kind: .suggestedChange, projectId: params.project_id, figure: params.figure ?? "",
                body: params.body, suggestedValue: params.suggested_value, registry: registry)
            return try JSONEncoder().encode(Result(annotation_id: id))
        }
        guard params.suggested_value == nil else {
            throw MCPError.invalidArgument("`suggested_value` is for a `figure` note; a paragraph takes `suggested_text`.")
        }
        guard let suggestedText = params.suggested_text else {
            throw MCPError.invalidArgument("`suggested_text` is required for a paragraph suggestion.")
        }
        let activePass = activeReviewPassId(
            projectId: params.project_id, documentId: documentId,
            registry: registry)
        let id = try await withAnnotationDocument(
            projectId: params.project_id,
            documentId: documentId,
            registry: registry
        ) { doc in
            let span = try resolveSpanAnchor(
                quote: params.quote, paragraphId: paragraphId, in: doc)
            return try await doc.addAnnotation(
                kind: .suggestedChange,
                paragraphId: paragraphId,
                body: params.body,
                suggestedText: suggestedText,
                toolArgs: annotationToolArgsJSON(params),
                span: span,
                author: claudeAnnotationAuthor,
                reviewPassId: activePass)
        }
        return try JSONEncoder().encode(Result(annotation_id: id))
    }
}

// MARK: - add_query

public enum AddQueryTool: MCPTool {
    public struct Params: Codable {
        public let project_id: String
        public let document_id: String?
        public let paragraph_id: String?
        public let figure: String?
        public let body: String
        public let quote: String?
        public let language: String?
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
        "sub-paragraph span; omit it to anchor the whole paragraph. During a " +
        "translation pass, pass `language` (the target tag, e.g. `es`) to mark " +
        "the query as a translator question about that language — " +
        "translation_status counts these as `open_queries`. To ask about a table " +
        "figure instead, pass `figure` (tbl:name, tbl:name!C3 or tbl:name!C3:E3) " +
        "and omit `document_id`, `paragraph_id` and `quote`."
    public static let inputSchemaJSON =
        #"{"type":"object","properties":{"project_id":{"type":"string"},"document_id":{"type":"string"},"paragraph_id":{"type":"string"},"figure":{"type":"string","description":"a table figure instead of a paragraph: tbl:name, tbl:name!C3 or tbl:name!C3:E3"},"body":{"type":"string"},"quote":{"type":"string"},"language":{"type":"string","description":"optional translation-pass target tag, e.g. es, pt-br"}},"required":["project_id","body"]}"#

    @MainActor
    public static func handle(
        paramsJSON: Data?, registry: ProjectRegistry
    ) async throws -> Data {
        let params = try decodeParams(Params.self, from: paramsJSON)
        if let language = params.language,
           !TranslationRecord.isValidLanguageTag(language) {
            throw MCPError.invalidArgument("invalid language tag: \(language)")
        }
        let target = try AnnotationTarget.resolve(
            figure: params.figure, documentId: params.document_id, paragraphId: params.paragraph_id)
        guard case .paragraph(let documentId, let paragraphId) = target else {
            guard params.quote == nil else {
                throw MCPError.invalidArgument("`quote` anchors text in a paragraph; a figure note has none.")
            }
            let id = try await addFigureNote(
                kind: .query, projectId: params.project_id, figure: params.figure ?? "",
                body: params.body, language: params.language, registry: registry)
            return try JSONEncoder().encode(Result(annotation_id: id))
        }
        let activePass = activeReviewPassId(
            projectId: params.project_id, documentId: documentId,
            registry: registry)
        let id = try await withAnnotationDocument(
            projectId: params.project_id,
            documentId: documentId,
            registry: registry
        ) { doc in
            let span = try resolveSpanAnchor(
                quote: params.quote, paragraphId: paragraphId, in: doc)
            return try await doc.addAnnotation(
                kind: .query,
                paragraphId: paragraphId,
                body: params.body,
                toolArgs: annotationToolArgsJSON(params),
                span: span,
                author: claudeAnnotationAuthor,
                reviewPassId: activePass)
        }
        return try JSONEncoder().encode(Result(annotation_id: id))
    }
}

// MARK: - add_craft_note

public enum AddCraftNoteTool: MCPTool {
    public struct Params: Codable {
        public let project_id: String
        public let document_id: String?
        public let figure: String?
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
        "for next-session reference. Pass `figure` (tbl:name, no cell) instead of " +
        "`document_id` for a craft observation about a whole table figure."
    public static let inputSchemaJSON =
        #"{"type":"object","properties":{"project_id":{"type":"string"},"document_id":{"type":"string"},"figure":{"type":"string","description":"a table figure instead of a document, whole figure only: tbl:name"},"body":{"type":"string"}},"required":["project_id","body"]}"#

    @MainActor
    public static func handle(
        paramsJSON: Data?, registry: ProjectRegistry
    ) async throws -> Data {
        let params = try decodeParams(Params.self, from: paramsJSON)
        let target = try AnnotationTarget.resolve(
            figure: params.figure, documentId: params.document_id, paragraphId: nil,
            needsParagraph: false)
        guard case .paragraph(let documentId, _) = target else {
            let id = try await addFigureNote(
                kind: .craftNote, projectId: params.project_id, figure: params.figure ?? "",
                body: params.body, registry: registry)
            return try JSONEncoder().encode(Result(annotation_id: id))
        }
        // Nil whenever the piece is closed — which is the case M5-AN-048 pins
        // for this tool in particular. The note still lands; it belongs to no
        // pass, and so appears under every one.
        let activePass = activeReviewPassId(
            projectId: params.project_id, documentId: documentId,
            registry: registry)
        let id = try await withAnnotationDocument(
            projectId: params.project_id,
            documentId: documentId,
            registry: registry
        ) { doc in
            try await doc.addAnnotation(
                kind: .craftNote,
                paragraphId: nil,
                body: params.body,
                toolArgs: annotationToolArgsJSON(params),
                reviewPassId: activePass)
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
