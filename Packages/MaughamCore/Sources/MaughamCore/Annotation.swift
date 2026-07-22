import Foundation

public enum AnnotationKind: String, Codable, Equatable, Sendable, CaseIterable {
    case comment
    case suggestedChange = "suggested_change"
    case query
    case craftNote = "craft_note"
}

public enum AnnotationStatus: String, Codable, Equatable, Sendable, CaseIterable {
    case open
    case accepted
    case rejected
    case archived
}

public struct Annotation: Equatable, Sendable, Identifiable {
    public let id: String                  // = op_id of the creation op
    public let kind: AnnotationKind
    public let paragraphId: String?        // nil only for .craftNote
    public let body: String                // Claude's prose
    public let suggestedText: String?      // .suggestedChange only
    public let priorText: String?          // captured at suggestion time
    public let createdAt: Date
    public let createdBySession: String?
    public let status: AnnotationStatus
    public let userResponse: String?
    public let resolvedAt: Date?
    public let isStale: Bool
    public let author: AnnotationAuthor?         // who created it (provenance)
    public let span: SpanAnchor?                 // sub-paragraph anchor, if any
    public let resolvedSpanRange: Range<Int>?    // re-resolved against live text
    public let language: String?                 // .query only: translation-pass language tag

    public init(
        id: String, kind: AnnotationKind, paragraphId: String?,
        body: String, suggestedText: String?, priorText: String?,
        createdAt: Date, createdBySession: String?,
        status: AnnotationStatus, userResponse: String?,
        resolvedAt: Date?, isStale: Bool,
        author: AnnotationAuthor? = nil, span: SpanAnchor? = nil,
        resolvedSpanRange: Range<Int>? = nil,
        language: String? = nil
    ) {
        self.id = id; self.kind = kind; self.paragraphId = paragraphId
        self.body = body; self.suggestedText = suggestedText
        self.priorText = priorText; self.createdAt = createdAt
        self.createdBySession = createdBySession
        self.status = status; self.userResponse = userResponse
        self.resolvedAt = resolvedAt; self.isStale = isStale
        self.author = author; self.span = span
        self.resolvedSpanRange = resolvedSpanRange
        self.language = language
    }
}

public struct AnnotationFilter: Equatable, Sendable {
    public var kinds: Set<AnnotationKind>?
    public var statuses: Set<AnnotationStatus>?
    public var paragraphId: String?

    public init(
        kinds: Set<AnnotationKind>? = nil,
        statuses: Set<AnnotationStatus>? = [.open],
        paragraphId: String? = nil
    ) {
        self.kinds = kinds
        self.statuses = statuses
        self.paragraphId = paragraphId
    }
}

extension AnnotationKind {
    /// Maps an annotation creation OpKind to its AnnotationKind, or nil if
    /// the op is not a creation op.
    public static func fromOpKind(_ kind: OpKind) -> AnnotationKind? {
        switch kind {
        case .claudeComment:    return .comment
        case .claudeSuggestion: return .suggestedChange
        case .claudeQuery:      return .query
        case .claudeCraftNote:  return .craftNote
        default:                return nil
        }
    }

    /// SF Symbol name for this kind. SINGLE SOURCE — both the Mac AnnotationsPane
    /// and the iOS AnnotationsList/Detail consume this so the icon never differs
    /// across surfaces. (Cross-surface contract; see docs/superpowers/notes/cross-surface-contracts.md.)
    public var systemImageName: String {
        switch self {
        case .comment:         return "bubble.left"
        case .suggestedChange: return "pencil.line"
        case .query:           return "questionmark.circle"
        case .craftNote:       return "lightbulb"
        }
    }

    /// Human-facing label for this kind. Single source, consumed by both surfaces.
    public var displayName: String {
        switch self {
        case .comment:         return "Comment"
        case .suggestedChange: return "Suggested change"
        case .query:           return "Query"
        case .craftNote:       return "Craft note"
        }
    }
}
