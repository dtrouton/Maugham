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
    /// The writer read the note, considered it, and the words stand (M3 P2).
    /// Widening this enum is safe where widening a wire enum would not be: the
    /// status is a PROJECTION derived from op kinds, never decoded from disk,
    /// which is also why it has no `.unknown` case.
    case stetted
}

/// What the writer intends to do about an OPEN note — the queue's sort key
/// (M3 P2). A mark, not a resolution: a triaged note is still open, and
/// clearing the mark returns it to untriaged (`nil`).
///
/// No `.unknown` case, for `AnnotationStatus`'s reason: this is a projection
/// the deriver parses out of `Op.Provenance.triageMark` and never re-encodes,
/// so an unrecognised raw value derives `nil` rather than degrading the op —
/// the raw string on the wire is untouched and a newer build still reads it.
public enum TriageMark: String, Codable, Equatable, Sendable, CaseIterable {
    case `do`
    case decline
    case discuss
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
    /// RULING-31: after a reopen, the most recent rejection's written reason
    /// stays part of the note's record — the pane shows it as
    /// "previously rejected: …". Nil when the note was never rejected or is
    /// not currently open.
    public let previousRejectionReason: String?
    /// The writer's triage of this OPEN note (M3 P2) — the latest
    /// `annotation_triage` op's mark, or nil for untriaged. Independent of
    /// `status`: triage sorts the queue, it never settles a note.
    public let triage: TriageMark?
    /// The `ReviewPass.id` that was active when the note was created (M3 P2),
    /// stamped on the creation op's provenance. Nil for every note written
    /// before passes existed, and for any written with no active pass.
    public let reviewPassId: String?

    public init(
        id: String, kind: AnnotationKind, paragraphId: String?,
        body: String, suggestedText: String?, priorText: String?,
        createdAt: Date, createdBySession: String?,
        status: AnnotationStatus, userResponse: String?,
        resolvedAt: Date?, isStale: Bool,
        author: AnnotationAuthor? = nil, span: SpanAnchor? = nil,
        resolvedSpanRange: Range<Int>? = nil,
        language: String? = nil,
        previousRejectionReason: String? = nil,
        triage: TriageMark? = nil,
        reviewPassId: String? = nil
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
        self.previousRejectionReason = previousRejectionReason
        self.triage = triage
        self.reviewPassId = reviewPassId
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
