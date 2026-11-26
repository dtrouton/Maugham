import SwiftUI

/// **Where the tree's section titles and their chevrons sit, and how they
/// look** (owner's hand check, 2026-11-21: *"the tree seems to indent research
/// and then palette"*).
///
/// Research and Figures are `Section` HEADERS; the Palette is a selectable
/// ROW (selecting it opens the wall). A sidebar `List` lays a header's content
/// out from x=14 and a top-level row's cell from x=25, past the outline's
/// disclosure gutter (x=12…25), and styles the two differently — so one
/// drawn chevron had landed at two x's in two weights, and Palette read as
/// nested under Research.
///
/// Now the Palette is a `DisclosureGroup` and its triangle is the outline's
/// own, in the gutter beside every chapter's fold; Research's and Figures'
/// headers draw theirs centred on that gutter and start their titles where a
/// row's cell starts. Every number here was measured on macOS 27 at the
/// default sidebar size — in a bare `BinderView`, a `CollectionPiecesPane`
/// and the real `ProjectWindow` alike — and `TreeTopLevelAlignmentTests`
/// re-measures it, so a later SDK that moves the gutter turns that suite red
/// rather than this comment stale.
enum TreeSectionColumn {
    /// Where a section header's content starts.
    static let headerContentX: CGFloat = 14
    /// Where a top-level row's cell starts — the disclosure gutter's trailing
    /// edge (`NSOutlineView.frameOfOutlineCell(atRow:)` = (12, y, 13, h)).
    static let rowCellX: CGFloat = 25
    /// The gutter's centre, where a row's triangle is drawn.
    static let gutterCentreX: CGFloat = 18.5

    /// A header chevron's glyph box: centred on the gutter's centre.
    static let chevronBox: CGFloat = 2 * (gutterCentreX - headerContentX)
    /// After the box, so the header's title starts where a row's does. The
    /// button's hit area covers it.
    static let chevronTrail: CGFloat = rowCellX - headerContentX - chevronBox

    /// Where a chevron-less header (Editions) starts its text: the titles'
    /// column, so every section title starts at one x.
    static let chevronlessHeaderInset: CGFloat = rowCellX - headerContentX

    /// The one section-title look: what a sidebar `Section` header draws on
    /// its own — measured pixel-identical to `.subheadline` semibold in
    /// `.tertiary`, in the gate's (inactive) window — spelled out so the
    /// Palette ROW can wear it too.
    static let titleFont: Font = .subheadline.weight(.semibold)
    /// The header chevron's glyph: at this size its closed ink is a row
    /// triangle's own (x=16…21, measured), so the column reads as one.
    static let chevronFont: Font = .system(size: 9, weight: .bold)
}

/// A section title or chevron, quiet until its row is selected: on the
/// accent fill (`backgroundProminence == .increased`, which a `List` sets on
/// its selected row) it turns `.primary`, i.e. white, as a row's text does.
///
/// **A title that names a subject turns `.primary` under its row's mark
/// too** (`TreeRowStateMark`): the Palette open in the centre while another
/// row holds the selection wears the open row's soft accent fill, as every
/// open row does, and a tertiary title on it read as a faint pill around a
/// faint word (owner's hand check, 2026-11-21).
private struct TreeSectionInk: ViewModifier {
    let rest: HierarchicalShapeStyle
    var subject: BinderSubject? = nil
    @Environment(\.backgroundProminence) private var prominence
    @Environment(\.treeRowMarks) private var marks

    private var isMarked: Bool {
        guard let subject else { return false }
        return marks.open == subject || marks.outlined.contains(subject)
    }

    func body(content: Content) -> some View {
        content.foregroundStyle(prominence == .increased || isMarked ? .primary : rest)
    }
}

extension View {
    /// A section title: Research, Figures, Palette, Editions. `subject` is
    /// the subject the title's row opens (the Palette's), when it has one.
    func treeSectionTitle(subject: BinderSubject? = nil) -> some View {
        font(TreeSectionColumn.titleFont)
            .modifier(TreeSectionInk(rest: .tertiary, subject: subject))
    }

    /// A header chevron's glyph, in a row triangle's grey.
    func treeSectionChevron() -> some View {
        font(TreeSectionColumn.chevronFont)
            .modifier(TreeSectionInk(rest: .secondary))
    }
}
