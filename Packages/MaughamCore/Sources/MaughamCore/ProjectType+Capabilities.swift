import Foundation

/// The questions callers ask of a project's kind, answered once here so Mac
/// and phone never spell them twice (tripwire 19). Every switch is exhaustive
/// and answers `.unknown` (ADR 0015) explicitly.
extension ProjectType {

    /// The format a new manuscript in this kind of project is written in.
    /// A collection holds pieces in either format, but its default is Markdown,
    /// as is an `.unknown` kind's.
    public var primaryFormat: DocumentFormat {
        switch self {
        case .screenplay: return .fountain
        case .shortStory, .novel, .collection, .unknown: return .markdown
        }
    }

    /// True when the book is a flat set of independent pieces, each in its own
    /// format (a collection).
    public var holdsPieces: Bool {
        switch self {
        case .collection: return true
        case .shortStory, .novel, .screenplay, .unknown: return false
        }
    }

    /// True when the project's manuscript is prose, which is where a figure
    /// (an image, a table, a chart) can be placed. A screenplay and an
    /// `.unknown` kind hold none.
    public var holdsFigures: Bool {
        switch self {
        case .shortStory, .novel, .collection: return true
        case .screenplay, .unknown: return false
        }
    }

    /// The SF Symbol that stands for this kind of project.
    public var symbolName: String {
        switch self {
        case .shortStory: return "doc.text"
        case .novel: return "book.closed"
        case .screenplay: return "film"
        case .collection: return "books.vertical"
        case .unknown: return "questionmark.folder"
        }
    }

    /// The kind a collection piece in `format` becomes when it is promoted to
    /// a project of its own.
    public static func forPromotedPiece(format: DocumentFormat) -> ProjectType {
        switch format {
        case .fountain: return .screenplay
        case .markdown: return .shortStory
        }
    }
}
