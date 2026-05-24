import Foundation

/// The on-disk envelope for a single operation in a document's op log.
/// See docs/superpowers/specs/2026-05-17-document-operation-log-design.md §1.2.
public struct Op: Codable, Equatable, Sendable {
    public let opId: String
    public let docId: String
    public let at: Date
    public let device: String
    public let session: String
    public let kind: OpKind
    public let changes: [ParagraphChange]
    public let sequence: [String]?
    public let provenance: Provenance?

    public struct ParagraphChange: Codable, Equatable, Sendable {
        public let paragraphId: String
        public let prior: String?
        public let next: String

        enum CodingKeys: String, CodingKey {
            case paragraphId = "paragraph_id"
            case prior, next
        }

        public init(paragraphId: String, prior: String?, next: String) {
            self.paragraphId = paragraphId
            self.prior = prior
            self.next = next
        }
    }

    public struct Provenance: Codable, Equatable, Sendable {
        public let sessionId: String?
        public let prompt: String?
        public let toolArgs: String?
        public let sourceCheckpoint: String?
        public let synthesisSource: SynthesisSource?
        public let orphanRecoveryMethod: String?

        // Annotation semantics — populated only on claude_* ops.
        public let annotationBody: String?
        public let sourceAnnotationId: String?
        public let userResponse: String?

        // Task semantics — populated only on task_* ops.
        public let taskId: String?
        public let taskBody: String?
        public let taskStatus: String?
        public let taskPriority: Double?
        public let taskParentId: String?
        public let taskKind: String?

        enum CodingKeys: String, CodingKey {
            case sessionId = "session_id"
            case prompt
            case toolArgs = "tool_args"
            case sourceCheckpoint = "source_checkpoint"
            case synthesisSource = "synthesis_source"
            case orphanRecoveryMethod = "orphan_recovery_method"
            case annotationBody = "annotation_body"
            case sourceAnnotationId = "source_annotation_id"
            case userResponse = "user_response"
            case taskId = "task_id"
            case taskBody = "task_body"
            case taskStatus = "task_status"
            case taskPriority = "task_priority"
            case taskParentId = "task_parent_id"
            case taskKind = "task_kind"
        }

        public init(
            sessionId: String? = nil, prompt: String? = nil,
            toolArgs: String? = nil, sourceCheckpoint: String? = nil,
            synthesisSource: SynthesisSource? = nil, orphanRecoveryMethod: String? = nil,
            annotationBody: String? = nil, sourceAnnotationId: String? = nil,
            userResponse: String? = nil,
            taskId: String? = nil, taskBody: String? = nil,
            taskStatus: String? = nil, taskPriority: Double? = nil,
            taskParentId: String? = nil, taskKind: String? = nil
        ) {
            self.sessionId = sessionId
            self.prompt = prompt
            self.toolArgs = toolArgs
            self.sourceCheckpoint = sourceCheckpoint
            self.synthesisSource = synthesisSource
            self.orphanRecoveryMethod = orphanRecoveryMethod
            self.annotationBody = annotationBody
            self.sourceAnnotationId = sourceAnnotationId
            self.userResponse = userResponse
            self.taskId = taskId
            self.taskBody = taskBody
            self.taskStatus = taskStatus
            self.taskPriority = taskPriority
            self.taskParentId = taskParentId
            self.taskKind = taskKind
        }
    }

    enum CodingKeys: String, CodingKey {
        case opId = "op_id"
        case docId = "doc_id"
        case at, device, session, kind, changes, sequence, provenance
    }

    public init(
        opId: String, docId: String, at: Date, device: String,
        session: String, kind: OpKind, changes: [ParagraphChange],
        sequence: [String]? = nil, provenance: Provenance? = nil
    ) {
        self.opId = opId
        self.docId = docId
        self.at = at
        self.device = device
        self.session = session
        self.kind = kind
        self.changes = changes
        self.sequence = sequence
        self.provenance = provenance
    }
}
