import SwiftUI
import MaughamCore

/// The rows a table figure's card draws, in drawing order: header rows (bold),
/// body rows short of the total, the "+ N more rows" line, then the kept total
/// row ruled above — the order the Mac's drawn card uses.
struct FigureTablePlan: Equatable {
    var headerRows: [[String]]
    var bodyRows: [[String]]
    /// `FigureCardText.more(n)`, or nil when every row shows.
    var more: String?
    var totalRow: [String]?
    /// One per column, never `.automatic` (drawn left).
    var alignments: [CellAlignment]
    /// **Open-note dots** (report plan 9c-2): the marked columns of each row, parallel
    /// to `headerRows`, `bodyRows` and `totalRow`. Read-only: a dot is drawn, never tapped.
    var headerMarks: [Set<Int>] = []
    var bodyMarks: [Set<Int>] = []
    var totalMarks: Set<Int> = []

    var columnCount: Int { alignments.count }
}

/// **What a figure line draws on the phone** (report plan 9b Task 5, spec
/// §10.2): read-only, from Core's `FigureCardModel` and `FigureCardText`'s
/// words. Pure, so the tests assert it rather than pixels; the reader computes
/// one per figure line per load (tripwire 4) and looks it up per block.
///
/// No number and no "Research has changed" banner (plan 9b rulings).
enum FigureCardPlan: Equatable {
    /// The cards are still loading (the reader's state before its plans exist).
    case loading
    /// A labelled card: parked, ambiguous, empty, or not downloaded yet.
    case label(String)
    case table(FigureTablePlan)
    /// A picture, loaded through `PhoneImageLoader`.
    case picture(URL)
    /// Nothing under the caption: a picture line naming nothing local.
    case captionOnly

    /// - Parameters:
    ///   - card: `PhoneFigureBook.card(forLinePath:documentPath:)` after a
    ///     load; nil means a registered figure whose files have not arrived.
    ///   - imageURL: `PhoneFigureBook.imageURL(forLinePath:documentPath:)`.
    ///
    /// A `figures/` path the registry does not name (`.removed`) is not
    /// downloaded yet too: the phone cannot tell a removed figure from one
    /// whose registration has not synced, so it never says "Figure removed".
    static func plan(card: FigureCardModel?, imageURL: URL?) -> FigureCardPlan {
        guard let card else { return .label(FigureCardText.notReady) }
        switch card.kind {
        case .removed: return .label(FigureCardText.notReady)
        case .ambiguous: return .label(FigureCardText.ambiguous)
        case .parked: return .label(FigureCardText.parked)
        case .image: return imageURL.map(FigureCardPlan.picture) ?? .captionOnly
        case .table:
            guard card.shownRowCount > 0 else { return .label(FigureCardText.empty) }
            let columns = (card.headerRows + card.bodyRows).map(\.count).max() ?? 0
            let alignments = (0..<columns).map { i -> CellAlignment in
                let a = i < card.columnAlignments.count ? card.columnAlignments[i] : .left
                return a == .automatic ? .left : a
            }
            // `Position.row` indexes headerRows + bodyRows as shown (the total row last).
            func marks(_ rows: Range<Int>) -> [Set<Int>] {
                rows.map { r in Set(card.markedCells.filter { $0.row == r && $0.column < columns }.map(\.column)) }
            }
            let headerCount = card.headerRows.count
            let shown = card.shownRowCount
            let bodyEnd = card.hasTotalRow ? shown - 1 : shown
            return .table(FigureTablePlan(
                headerRows: card.headerRows,
                bodyRows: card.hasTotalRow ? Array(card.bodyRows.dropLast()) : card.bodyRows,
                more: card.moreRows > 0 ? FigureCardText.more(card.moreRows) : nil,
                totalRow: card.hasTotalRow ? card.bodyRows.last : nil,
                alignments: alignments,
                headerMarks: marks(0..<headerCount),
                bodyMarks: marks(headerCount..<max(bodyEnd, headerCount)),
                totalMarks: card.hasTotalRow ? marks((shown - 1)..<shown)[0] : []))
        }
    }

    /// Only the not-downloaded state offers Retry; a retry reloads the cards.
    var offersRetry: Bool { self == .label(FigureCardText.notReady) }

    var pictureURL: URL? {
        if case .picture(let url) = self { return url }
        return nil
    }

    /// Each distinct picture the plans draw, once, in a stable order.
    static func picturesToLoad(_ plans: [String: FigureCardPlan]) -> [URL] {
        Array(Set(plans.values.compactMap(\.pictureURL))).sorted { $0.path < $1.path }
    }
}

/// The card under a figure line: the plan's table, words or picture, then the
/// caption. Read-only: nothing here edits; the one button reloads the cards.
/// System fonts and colours, so Dynamic Type and dark mode follow the device.
struct FigureCardView: View {
    let caption: AttributedString
    let plan: FigureCardPlan
    /// The plan's picture once tried: nil while loading, `.some(nil)` failed.
    var picture: UIImage??
    var onRetry: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            content
            if !caption.characters.isEmpty {
                FigureCaption(text: caption)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var content: some View {
        switch plan {
        case .loading:
            boxed { ProgressView() }
        case .label(let words):
            boxed {
                HStack(spacing: 12) {
                    Text(words).font(.callout).foregroundStyle(.secondary)
                    if plan.offersRetry, let onRetry {
                        Button("Retry", action: onRetry)
                            .font(.callout)
                            .buttonStyle(.borderless)
                    }
                }
            }
        case .table(let table):
            tableView(table)
        case .picture:
            pictureView
        case .captionOnly:
            EmptyView()
        }
    }

    private func boxed<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color(.secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    /// A wide table scrolls sideways inside the card, never the page.
    private func tableView(_ table: FigureTablePlan) -> some View {
        ScrollView(.horizontal) {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                ForEach(Array(table.headerRows.enumerated()), id: \.offset) { i, row in
                    rowView(row, table, marks: i < table.headerMarks.count ? table.headerMarks[i] : [],
                            bold: true, setsAlignment: i == 0)
                }
                if !table.headerRows.isEmpty { Divider() }
                ForEach(Array(table.bodyRows.enumerated()), id: \.offset) { i, row in
                    rowView(row, table, marks: i < table.bodyMarks.count ? table.bodyMarks[i] : [],
                            bold: false, setsAlignment: i == 0 && table.headerRows.isEmpty)
                }
                if let more = table.more {
                    Text(more)
                        .font(.footnote).foregroundStyle(.secondary)
                        .gridCellColumns(max(table.columnCount, 1))
                }
                if let total = table.totalRow {
                    Divider()
                    rowView(total, table, marks: table.totalMarks, bold: false,
                            setsAlignment: table.headerRows.isEmpty && table.bodyRows.isEmpty)
                }
            }
            .padding(12)
        }
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    /// - setsAlignment: true on the first row drawn: a column's alignment is
    ///   set once, on one of its cells.
    private func rowView(_ row: [String], _ table: FigureTablePlan, marks: Set<Int>, bold: Bool,
                         setsAlignment: Bool) -> some View {
        GridRow {
            ForEach(0..<table.columnCount, id: \.self) { i in
                let cell = Text(i < row.count ? row[i] : "")
                    .font(.callout)
                    .fontWeight(bold ? .bold : .regular)
                    .monospacedDigit()
                    .lineLimit(1)
                    .overlay(alignment: .topTrailing) {
                        if marks.contains(i) {
                            Circle().fill(Self.noteDot).frame(width: 6, height: 6)
                                .offset(x: 6, y: -2)
                                .accessibilityLabel("Open note")
                        }
                    }
                if setsAlignment {
                    cell.gridColumnAlignment(Self.horizontal(table.alignments[i]))
                } else {
                    cell
                }
            }
        }
    }

    /// The assistant-note colour. The phone has no palette type; this is the Mac's
    /// `ReviewPalette.claudeTerracotta` value (0.78, 0.42, 0.32), stated here once.
    private static let noteDot = Color(.sRGB, red: 0.78, green: 0.42, blue: 0.32, opacity: 1)

    private static func horizontal(_ alignment: CellAlignment) -> HorizontalAlignment {
        switch alignment {
        case .right: return .trailing
        case .center: return .center
        case .left, .automatic: return .leading
        }
    }

    @ViewBuilder
    private var pictureView: some View {
        switch picture {
        case .some(.some(let image)):
            Image(uiImage: image)
                .resizable().aspectRatio(contentMode: .fit)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 8))
        case .some(.none):
            placeholder { Image(systemName: "photo.badge.exclamationmark").font(.title2) }
        case .none:
            placeholder { ProgressView() }
        }
    }

    private func placeholder<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(Color(.secondarySystemBackground))
            .frame(height: 120)
            .overlay { content().foregroundStyle(.secondary) }
    }
}

/// A figure's or a table's caption, inline emphasis already applied.
struct FigureCaption: View {
    let text: AttributedString

    var body: some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
