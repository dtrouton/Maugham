import Foundation
import MaughamCore

/// **What the project calls a piece — one word per thing** (shell p5 Task 6).
///
/// | Project | A piece | Plural | A group |
/// |---|---|---|---|
/// | Novel | chapter | chapters | Part |
/// | Short Story | story | stories | — |
/// | Collection | piece (a screenplay piece: script) | pieces | — |
/// | Screenplay | script | scripts | — |
/// | Report (any shape) | section | sections | Part |
///
/// The one noun function (`WordingCensusTests.test_oneNounFunction`): every
/// writer-facing sentence that names a piece, a group of pieces or a run of
/// them asks here. The kind is asked by profile, then by capability and an
/// exhaustive switch (tripwire 55); the item's own format by capability, so a
/// Fountain piece in a Collection is a script.
struct PieceNoun: Equatable, Sendable {
    /// "chapter".
    let singular: String
    /// "chapters".
    let plural: String
    /// The project's word for a group of pieces ("Part"); nil where it has
    /// none, and a group is just a group.
    let group: String?

    /// "Chapter".
    var capitalised: String { Self.capitalising(singular) }
    /// "Chapters".
    var capitalisedPlural: String { Self.capitalising(plural) }

    /// "1 chapter" / "3 chapters".
    func counted(_ count: Int) -> String {
        "\(count) \(count == 1 ? singular : plural)"
    }

    /// **What the project calls a book's kind** — the half of a manifest the
    /// noun reads, so a pure function that only names pieces takes this
    /// rather than a whole manifest.
    struct Book: Equatable, Sendable {
        let type: ProjectType
        let profile: ProjectProfile?

        init(type: ProjectType, profile: ProjectProfile? = nil) {
            self.type = type
            self.profile = profile
        }

        init(_ manifest: ProjectManifest) {
            self.init(type: manifest.type, profile: manifest.profile)
        }
    }

    /// The word for `item` (nil: a piece of the project in general) in the
    /// project `manifest` describes.
    static func of(_ item: StructureItem?, in manifest: ProjectManifest) -> PieceNoun {
        of(item, in: Book(manifest))
    }

    /// The word for `item` in `book`. A Report's pieces are sections whatever
    /// structure it sits on; a piece written in a screenplay format is a
    /// script wherever it is.
    static func of(_ item: StructureItem?, in book: Book) -> PieceNoun {
        switch book.profile {
        case .report?: return .section
        case .unknown?, nil: break
        }
        if book.type.primaryFormat.isScreenplay
            || DocumentFormat.ofManuscript(path: item?.path).isScreenplay {
            return .script
        }
        if book.type.holdsPieces { return .piece }
        switch book.type {
        case .novel: return .chapter
        case .shortStory: return .story
        // A newer build's kind is a project of pieces.
        case .screenplay, .collection, .unknown: return .piece
        }
    }

    static let chapter = PieceNoun(singular: "chapter", plural: "chapters", group: "Part")
    static let story = PieceNoun(singular: "story", plural: "stories", group: nil)
    static let piece = PieceNoun(singular: "piece", plural: "pieces", group: nil)
    static let script = PieceNoun(singular: "script", plural: "scripts", group: nil)
    static let section = PieceNoun(singular: "section", plural: "sections", group: "Part")

    private static func capitalising(_ word: String) -> String {
        word.prefix(1).uppercased() + word.dropFirst()
    }
}
