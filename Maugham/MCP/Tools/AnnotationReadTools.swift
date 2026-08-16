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
        /// The writer's triage of this note — `do` / `decline` / `discuss`, or
        /// null for untriaged (M3 P3). Claude never sets it.
        public let triage: String?
        /// The `ReviewPass.id` that was active when the note was written, or
        /// null. **Null means every pass, not no pass**: an unstamped note
        /// appears in every pass's queue.
        public let review_pass_id: String?

        enum CodingKeys: String, CodingKey {
            case id, kind, paragraph_id, body, suggested_text, status
            case user_response, created_at, resolved_at, is_stale
            case triage, review_pass_id
        }

        // Hand-written so the two M3 P3 fields emit JSON `null` rather than
        // vanishing: "untriaged" and "belongs to every pass" are FACTS a
        // reader has to be able to read off the wire, and an absent key says
        // "this tool does not report triage" instead. The pre-existing
        // optionals keep `encodeIfPresent` — their shape is a shipped wire
        // contract and changing it is not this widening's business.
        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(id, forKey: .id)
            try c.encode(kind, forKey: .kind)
            try c.encodeIfPresent(paragraph_id, forKey: .paragraph_id)
            try c.encode(body, forKey: .body)
            try c.encodeIfPresent(suggested_text, forKey: .suggested_text)
            try c.encode(status, forKey: .status)
            try c.encodeIfPresent(user_response, forKey: .user_response)
            try c.encode(created_at, forKey: .created_at)
            try c.encodeIfPresent(resolved_at, forKey: .resolved_at)
            try c.encode(is_stale, forKey: .is_stale)
            try c.encode(triage, forKey: .triage)
            try c.encode(review_pass_id, forKey: .review_pass_id)
        }
    }
    public static let method = "list_annotations"
    public static let description =
        "List annotations on a document. Defaults to status=open. Filter by " +
        "`kinds` (any of comment/suggested_change/query/craft_note), `statuses` " +
        "(open/accepted/rejected/archived/stetted — `stetted` means the writer " +
        "read the note and the words stand), `paragraph_id`. Use this to check " +
        "prior editorial conversation on a paragraph before adding new suggestions. " +
        "`review_pass_id` is the review pass a note was written under; a null one " +
        "belongs to EVERY pass, not to none. `triage` (do/decline/discuss) and " +
        "stetting are the writer's own marks — Claude never sets either."
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
        /// See `ListAnnotationsTool.Item.triage` — the same field, so the
        /// pair cannot disagree about a note.
        public let triage: String?
        /// See `ListAnnotationsTool.Item.review_pass_id`.
        public let review_pass_id: String?
        public let history: [HistoryEntry]

        public struct HistoryEntry: Codable, Equatable {
            public let op_id: String
            public let kind: String
            public let at: Date
            public let user_response: String?
        }

        enum CodingKeys: String, CodingKey {
            case id, kind, paragraph_id, body, suggested_text, prior_text
            case status, user_response, created_at, resolved_at, is_stale
            case triage, review_pass_id, history
        }

        // `ListAnnotationsTool.Item.encode`'s reasoning, applied to the
        // single-record sibling so the two agree key for key.
        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(id, forKey: .id)
            try c.encode(kind, forKey: .kind)
            try c.encodeIfPresent(paragraph_id, forKey: .paragraph_id)
            try c.encode(body, forKey: .body)
            try c.encodeIfPresent(suggested_text, forKey: .suggested_text)
            try c.encodeIfPresent(prior_text, forKey: .prior_text)
            try c.encode(status, forKey: .status)
            try c.encodeIfPresent(user_response, forKey: .user_response)
            try c.encode(created_at, forKey: .created_at)
            try c.encodeIfPresent(resolved_at, forKey: .resolved_at)
            try c.encode(is_stale, forKey: .is_stale)
            try c.encode(triage, forKey: .triage)
            try c.encode(review_pass_id, forKey: .review_pass_id)
            try c.encode(history, forKey: .history)
        }
    }
    public static let method = "get_annotation"
    public static let description =
        "Return a full annotation record including its lifecycle history " +
        "(creation + accept/reject/archive/stet ops). `review_pass_id` is the " +
        "review pass the note was written under; a null one belongs to EVERY " +
        "pass, not to none. `triage` (do/decline/discuss) and stetting are the " +
        "writer's own marks — Claude never sets either."
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
                is_stale: ann.isStale,
                triage: ann.triage?.rawValue,
                review_pass_id: ann.reviewPassId,
                history: history)
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
            resolved_at: ann.resolvedAt, is_stale: ann.isStale,
            triage: ann.triage?.rawValue, review_pass_id: ann.reviewPassId)
    }
}
