import SwiftUI
import MaughamCore

/// **The line naming what To resolve and Brief are about** (appraisal 2): on
/// the canvas, after an edition, or with a note pulled up, the piece the
/// panes follow (the faces) need not be the piece in the centre, and a writer
/// typing into Brief must see whose Brief it is. One quiet line, the faces'
/// title, at the top of both.
///
/// **No new state**: `title` is a function of the faces the panes already
/// render from, read off the manifest the pane already observes.
struct RightColumnSubjectLine: View {
    let title: String

    /// **The faces' title.** A piece or a Part: its title in the tree; the
    /// Book: the book's title; a figure: its name; an edition: "<Language>
    /// edition", as the tree's Editions rows name it. Nil where the faces name
    /// nothing the panes are about (the canvas, the Inbox, the Palette,
    /// research): there the panes say so themselves. Pure.
    static func title(of faces: BinderSubject, structure: [StructureItem],
                      bookTitle: String, figures: [FigureRecord]) -> String? {
        switch faces {
        case .project:
            return named(bookTitle, else: "The book")
        case .item(let id):
            guard let item = TreeWalk.find(id: id, in: structure) else { return nil }
            return named(item.title, else: "Untitled")
        case .figure(let id):
            return named(figures.first { $0.id == id }?.name ?? "", else: "Figure")
        case .edition(let language):
            return "\(TreeEditionRows.title(forLanguage: language)) edition"
        case .research, .inbox, .canvas, .palette:
            return nil
        }
    }

    /// **Brief's line over a piece read in a language** (closing review M5):
    /// a piece has one intent for every language, so Brief stays the
    /// piece's own — and says so, beside a To resolve that is the language's
    /// list: "Chapter 7 · Source brief". Every other Brief keeps its title.
    /// Pure.
    static func briefTitle(_ title: String, scope: BriefScope, readIn: String?) -> String {
        guard readIn != nil, case .piece = scope else { return title }
        return "\(title) \u{00B7} \(sourceBriefWord)"
    }

    static let sourceBriefWord = "Source brief"

    /// **Whether To resolve carries the line**: not where the faces are the
    /// piece open in the centre — even an empty one, even one still opening
    /// (`open` is the binder's pick, set before its `Document` registers) —
    /// for there the name is what the writer already has selected. Anywhere
    /// the faces and the centre part (the canvas, an edition's book, a Brief
    /// link, ⌘⌥K), or the faces are not a piece, it stays. Brief keeps its
    /// line always: a writer typing into it must see whose it is. Pure.
    static func showsOverToResolve(_ subject: WindowSubject) -> Bool {
        guard case .item = subject.faces else { return true }
        return subject.open != subject.faces
    }

    private static func named(_ title: String, else fallback: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : trimmed
    }

    var body: some View {
        Text(title)
            .font(.callout.weight(.semibold))
            .lineLimit(1)
            .truncationMode(.middle)
            .help(title)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 2)
            .accessibilityAddTraits(.isHeader)
            .accessibilityIdentifier("rightColumn.subject")
    }
}
