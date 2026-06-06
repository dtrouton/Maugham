import Foundation
import MaughamCore

// MARK: - list_annotations

public enum ListAnnotationsTool: MCPTool {
    public struct Params: Codable {
        public let project_id: String
        public let document_id: String
        public let kinds: [String]?
        public let statuses: [String]?
        public let paragraph_id: String?
    }
    public struct Item: Codable, Equatable {
        public let id: String
        public let kind: String
        public let paragraph_id: String?
        public let body: String
        public let suggested_text: String?
        public let status: String
        public let user_response: String?
        public let created_at: Date
        public let resolved_at: Date?
        public let is_stale: Bool
    }
    public static let method = "list_annotations"
    public static let description =
        "List annotations on a document. Defaults to status=open. Filter by " +
        "`kinds` (any of comment/suggested_change/query/craft_note), `statuses` " +
        "(open/accepted/rejected/archived), `paragraph_id`. Use this to check " +
        "prior editorial conversation on a paragraph before adding new suggestions."
    public static let inputSchemaJSON =
        #"{"type":"object","properties":{"project_id":{"type":"string"},"document_id":{"type":"string"},"kinds":{"type":"array","items":{"type":"string"}},"statuses":{"type":"array","items":{"type":"string"}},"paragraph_id":{"type":"string"}},"required":["project_id","document_id"]}"#

    @MainActor
    public static func handle(
        paramsJSON: Data?, registry: ProjectRegistry
    ) async throws -> Data {
        let params = try decodeParams(Params.self, from: paramsJSON)
        let kindFilter: Set<AnnotationKind>? = params.kinds.flatMap { raws in
            let set = Set(raws.compactMap(AnnotationKind.init(rawValue:)))
            return set.isEmpty ? nil : set
        }
        // Default = open only. Explicit empty array also collapses to default.
        let statusFilter: Set<AnnotationStatus> = params.statuses.flatMap { raws in
            let set = Set(raws.compactMap(AnnotationStatus.init(rawValue:)))
            return set.isEmpty ? nil : set
        } ?? [.open]
        let filter = AnnotationFilter(
            kinds: kindFilter,
            statuses: statusFilter,
            paragraphId: params.paragraph_id)

        let items: [Item] = try await withAnnotationDocument(
            projectId: params.project_id,
            documentId: params.document_id,
            registry: registry
        ) { doc in
            doc.annotations(filter: filter).map(Item.init)
        }
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        return try enc.encode(items)
    }
}

// MARK: - get_annotation

public enum GetAnnotationTool: MCPTool {
    public struct Params: Codable {
        public let project_id: String
        public let document_id: String
        public let annotation_id: String
    }
    public struct Result: Codable, Equatable {
        public let id: String
        public let kind: String
        public let paragraph_id: String?
        public let body: String
        public let suggested_text: String?
        public let prior_text: String?
        public let status: String
        public let user_response: String?
        public let created_at: Date
        public let resolved_at: Date?
        public let is_stale: Bool
        public let history: [HistoryEntry]

        public struct HistoryEntry: Codable, Equatable {
            public let op_id: String
            public let kind: String
            public let at: Date
            public let user_response: String?
        }
    }
    public static let method = "get_annotation"
    public static let description =
        "Return a full annotation record including its lifecycle history " +
        "(creation + accept/reject/archive ops)."
    public static let inputSchemaJSON =
        #"{"type":"object","properties":{"project_id":{"type":"string"},"document_id":{"type":"string"},"annotation_id":{"type":"string"}},"required":["project_id","document_id","annotation_id"]}"#

    @MainActor
    public static func handle(
        paramsJSON: Data?, registry: ProjectRegistry
    ) async throws -> Data {
        let params = try decodeParams(Params.self, from: paramsJSON)
        let result: Result = try await withAnnotationDocument(
            projectId: params.project_id,
            documentId: params.document_id,
            registry: registry
        ) { doc in
            let all = doc.annotations(filter: .init(statuses: nil))
            guard let ann = all.first(where: { $0.id == params.annotation_id })
            else {
                throw MCPError.invalidArgument(
                    "annotation_id not found: \(params.annotation_id)")
            }
            let ops = try await doc.opLog()
            let history: [Result.HistoryEntry] = ops
                .filter {
                    $0.opId == params.annotation_id
                    || $0.provenance?.sourceAnnotationId == params.annotation_id
                }
                .map { op in
                    Result.HistoryEntry(
                        op_id: op.opId,
                        kind: op.kind.rawValue,
                        at: op.at,
                        user_response: op.provenance?.userResponse)
                }
            return Result(
                id: ann.id, kind: ann.kind.rawValue,
                paragraph_id: ann.paragraphId, body: ann.body,
                suggested_text: ann.suggestedText, prior_text: ann.priorText,
                status: ann.status.rawValue, user_response: ann.userResponse,
                created_at: ann.createdAt, resolved_at: ann.resolvedAt,
                is_stale: ann.isStale, history: history)
        }
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        return try enc.encode(result)
    }
}

extension ListAnnotationsTool.Item {
    init(_ ann: Annotation) {
        self.init(
            id: ann.id, kind: ann.kind.rawValue,
            paragraph_id: ann.paragraphId, body: ann.body,
            suggested_text: ann.suggestedText, status: ann.status.rawValue,
            user_response: ann.userResponse, created_at: ann.createdAt,
            resolved_at: ann.resolvedAt, is_stale: ann.isStale)
    }
}
