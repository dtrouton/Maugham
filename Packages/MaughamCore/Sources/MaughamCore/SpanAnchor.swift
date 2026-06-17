import Foundation

/// A sub-paragraph anchor: the quoted span plus surrounding context for robust,
/// stateless re-find. `posHint` is a grapheme offset captured at creation, used
/// only as a tiebreaker when the quote/context are ambiguous.
public struct SpanAnchor: Codable, Equatable, Sendable {
    public let quote: String
    public let prefix: String
    public let suffix: String
    public let posHint: Int

    public init(quote: String, prefix: String, suffix: String, posHint: Int) {
        self.quote = quote
        self.prefix = prefix
        self.suffix = suffix
        self.posHint = posHint
    }
}

/// Who created an annotation. The annotation *kind* is source-agnostic;
/// provenance is the authority for "who".
public struct AnnotationAuthor: Codable, Equatable, Sendable {
    public enum SourceKind: String, Codable, Equatable, Sendable {
        case claude
        case human
    }
    public let sourceKind: SourceKind
    public let displayName: String
    public let collaboratorId: String?

    public init(sourceKind: SourceKind, displayName: String, collaboratorId: String? = nil) {
        self.sourceKind = sourceKind
        self.displayName = displayName
        self.collaboratorId = collaboratorId
    }
}
