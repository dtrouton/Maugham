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

        // Forensic metadata — populated only by phone-written ops (the iOS
        // annotation-review path). Mac writes leave these nil; the deriver
        // ignores them. Additive: existing op logs decode with both nil.
        public let appVersion: String?
        public let osVersion: String?

        // Annotation author — who created the annotation (source-agnostic kind;
        // provenance is the authority for "who"). Surfaced as AnnotationAuthor
        // by the deriver. Additive: legacy op logs decode with all nil.
        public let authorSourceKind: String?
        public let authorDisplayName: String?
        public let authorCollaboratorId: String?

        // Sub-paragraph span anchor — the quoted span plus surrounding context
        // for stateless re-find. Surfaced as SpanAnchor by the deriver, which
        // resolves it against the live paragraph on every derive.
        public let spanQuote: String?
        public let spanPrefix: String?
        public let spanSuffix: String?
        public let spanPosHint: Int?

        // Triage mark — populated only on `annotation_triage` ops: the raw
        // `TriageMark` value the writer sorted this note into, or nil for
        // "back to untriaged". Kept a raw `String?` for the same reason every
        // other tolerant field is: an unrecognised mark written by a newer
        // build must survive the round-trip rather than degrade. The deriver
        // parses it to `TriageMark?`. Additive: legacy op logs decode with all
        // nil.
        public let triageMark: String?

        // Review-pass stamp — the id of the pass that was active when this
        // annotation was created (`ReviewPass.id`; M3 P1's presets or the
        // project's own). Surfaced as `Annotation.reviewPassId`. A flat
        // optional scalar deliberately, never smuggled through `toolArgs` —
        // the `language` tag is the anti-precedent, and it is still the one
        // annotation field a reader has to JSON-decode a string to reach.
        public let reviewPassId: String?

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
            case appVersion = "app_version"
            case osVersion = "os_version"
            case authorSourceKind = "author_source_kind"
            case authorDisplayName = "author_display_name"
            case authorCollaboratorId = "author_collaborator_id"
            case spanQuote = "span_quote"
            case spanPrefix = "span_prefix"
            case spanSuffix = "span_suffix"
            case spanPosHint = "span_pos_hint"
            case triageMark = "triage_mark"
            case reviewPassId = "review_pass_id"
        }

        public init(
            sessionId: String? = nil, prompt: String? = nil,
            toolArgs: String? = nil, sourceCheckpoint: String? = nil,
            synthesisSource: SynthesisSource? = nil, orphanRecoveryMethod: String? = nil,
            annotationBody: String? = nil, sourceAnnotationId: String? = nil,
            userResponse: String? = nil,
            taskId: String? = nil, taskBody: String? = nil,
            taskStatus: String? = nil, taskPriority: Double? = nil,
            taskParentId: String? = nil, taskKind: String? = nil,
            appVersion: String? = nil, osVersion: String? = nil,
            authorSourceKind: String? = nil, authorDisplayName: String? = nil,
            authorCollaboratorId: String? = nil,
            spanQuote: String? = nil, spanPrefix: String? = nil,
            spanSuffix: String? = nil, spanPosHint: Int? = nil,
            triageMark: String? = nil, reviewPassId: String? = nil
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
            self.appVersion = appVersion
            self.osVersion = osVersion
            self.authorSourceKind = authorSourceKind
            self.authorDisplayName = authorDisplayName
            self.authorCollaboratorId = authorCollaboratorId
            self.spanQuote = spanQuote
            self.spanPrefix = spanPrefix
            self.spanSuffix = spanSuffix
            self.spanPosHint = spanPosHint
            self.triageMark = triageMark
            self.reviewPassId = reviewPassId
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

    /// Returns a copy of this op with `opId` replaced. All other fields are
    /// preserved identically. Used by `Document.rebuildTasksCache` to rewrite
    /// `TaskDeriver`'s placeholder rebalance op ids (`rebalance_<task_id>`)
    /// into the project's standard `ULID.generate()` format before appending.
    public func withReplacedOpId(_ newOpId: String) -> Op {
        Op(
            opId: newOpId, docId: docId, at: at, device: device,
            session: session, kind: kind, changes: changes,
            sequence: sequence, provenance: provenance)
    }
}
