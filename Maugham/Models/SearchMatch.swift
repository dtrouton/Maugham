import Foundation

/// Which side of the project a search match came from.
public enum SearchDocumentSource: String, Codable, Sendable, Equatable {
    case manuscript
    case research
}

/// One occurrence of the search query inside a document.
public struct SearchMatch: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let documentPath: String
    public let documentTitle: String
    public let documentSource: SearchDocumentSource
    public let lineNumber: Int                // 1-indexed
    public let charRangeInDocument: NSRange   // Whole-document character range
    public let linePreview: String             // Possibly-truncated containing line
    public let matchRangeInLine: NSRange      // Range within linePreview to highlight

    public init(
        id: UUID = UUID(),
        documentPath: String,
        documentTitle: String,
        documentSource: SearchDocumentSource,
        lineNumber: Int,
        charRangeInDocument: NSRange,
        linePreview: String,
        matchRangeInLine: NSRange
    ) {
        self.id = id
        self.documentPath = documentPath
        self.documentTitle = documentTitle
        self.documentSource = documentSource
        self.lineNumber = lineNumber
        self.charRangeInDocument = charRangeInDocument
        self.linePreview = linePreview
        self.matchRangeInLine = matchRangeInLine
    }
}

/// User-selectable matching options. Both default to false (case-insensitive
/// non-whole-word search).
public struct SearchOptions: Equatable, Sendable {
    public var caseSensitive: Bool
    public var wholeWord: Bool

    public init(caseSensitive: Bool = false, wholeWord: Bool = false) {
        self.caseSensitive = caseSensitive
        self.wholeWord = wholeWord
    }
}

/// A finished search pass — query, options, all matches sorted by
/// (source, document path, line number).
public struct SearchResults: Equatable, Sendable {
    public let query: String
    public let options: SearchOptions
    public let matches: [SearchMatch]

    public init(query: String, options: SearchOptions, matches: [SearchMatch]) {
        self.query = query
        self.options = options
        self.matches = matches
    }

    public var matchCount: Int { matches.count }
    public var documentCount: Int { Set(matches.map(\.documentPath)).count }
}
