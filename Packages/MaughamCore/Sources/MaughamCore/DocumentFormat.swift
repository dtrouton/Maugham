import Foundation

/// What kind of manuscript a file is, decided by its extension — the one home
/// for everything that decision implies: the extension itself, the held-blank
/// rule, the screenplay family, the syntax-help resource and the icon.
///
/// Mac and phone both ask this (tripwire 19). There is deliberately no raw
/// value and no `Codable`: a format is derived from the path every time and
/// can never become a wire or disk value by accident. Every property is an
/// exhaustive `switch self` — a new format must answer each one explicitly.
public enum DocumentFormat: CaseIterable, Sendable, Hashable {
    case markdown
    case fountain

    /// The lowercase extension Maugham writes for this format. The one place
    /// the Fountain extension is spelled.
    public var fileExtension: String {
        switch self {
        case .markdown: return "md"
        case .fountain: return "fountain"
        }
    }

    /// The format whose `fileExtension` matches `fileExtension`, compared
    /// case-insensitively; `nil` for anything else (`txt`, `markdown`, none).
    public init?(fileExtension: String) {
        let lowered = fileExtension.lowercased()
        guard let match = DocumentFormat.allCases.first(where: { $0.fileExtension == lowered })
        else { return nil }
        self = match
    }

    /// `init?(fileExtension:)` of the URL's path extension.
    public init?(url: URL) {
        self.init(fileExtension: url.pathExtension)
    }

    /// `init?(fileExtension:)` of the path's extension.
    public init?(path: String) {
        self.init(fileExtension: (path as NSString).pathExtension)
    }

    /// A manuscript's format: `.fountain` iff the extension is Fountain
    /// (case-insensitive), otherwise `.markdown` — the default every
    /// manuscript site has always used.
    public static func ofManuscript(url: URL) -> DocumentFormat {
        DocumentFormat(url: url) == .fountain ? .fountain : .markdown
    }

    /// `ofManuscript(url:)` for a path string.
    public static func ofManuscript(path: String) -> DocumentFormat {
        DocumentFormat(path: path) == .fountain ? .fountain : .markdown
    }

    /// Whether a whitespace-only line is held content inside its paragraph
    /// rather than a blank that splits it (E1: a Fountain dialogue pause is
    /// two spaces). Passed to `ParagraphParser.parse(_:preservesHeldBlankLines:)`.
    public var preservesHeldBlankLines: Bool {
        switch self {
        case .markdown: return false
        case .fountain: return true
        }
    }

    /// The screenplay family's one predicate: page targets, element gutter,
    /// sluglines, screenplay fonts, Fountain element drift. A future dialect
    /// answers it explicitly.
    public var isScreenplay: Bool {
        switch self {
        case .markdown: return false
        case .fountain: return true
        }
    }

    /// The bundled syntax-help resource (without extension) for this format.
    public var helpResourceName: String {
        switch self {
        case .markdown: return "markdown-syntax"
        case .fountain: return "fountain-syntax"
        }
    }

    /// The SF Symbol that stands for a document of this format.
    public var symbolName: String {
        switch self {
        case .markdown: return "doc.text"
        case .fountain: return "film"
        }
    }
}
