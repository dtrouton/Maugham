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

    var columnCount: Int { alignments.count }
}

/// **What a figure line draws on the phone** (report plan 9b Task 5, spec
/// §10.2): read-only, from Core's `FigureCardModel` and `FigureCardText`'s
/// words. Pure, so the tests assert it rather than pixels; the reader computes
/// one per figure line per load (tripwire 4) and looks it up per block.
///
/// No number and no "Research has changed" banner (plan 9b rulings).
enum FigureCardPlan: Equatable {
    /// The cards are still loading.
    case loading
    /// A labelled card: parked, removed, ambiguous, empty, or not downloaded yet.
    case label(String)
    case table(FigureTablePlan)
    /// A picture, loaded through `PhoneImageLoader`.
    case picture(URL)
    /// Nothing under the caption: a picture line naming nothing local.
    case captionOnly

    /// - Parameters:
    ///   - card: `PhoneFigureBook.card(forLinePath:documentPath:)`; nil after a
    ///     load means a registered figure whose files have not arrived.
    ///   - imageURL: `PhoneFigureBook.imageURL(forLinePath:documentPath:)`.
    ///   - loaded: whether the book has loaded.
    static func plan(card: FigureCardModel?, imageURL: URL?, loaded: Bool) -> FigureCardPlan {
        guard loaded else { return .loading }
        guard let card else { return .label(FigureCardText.notReady) }
        switch card.kind {
        case .removed: return .label(FigureCardText.removed)
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
            return .table(FigureTablePlan(
                headerRows: card.headerRows,
                bodyRows: card.hasTotalRow ? Array(card.bodyRows.dropLast()) : card.bodyRows,
                more: card.moreRows > 0 ? FigureCardText.more(card.moreRows) : nil,
                totalRow: card.hasTotalRow ? card.bodyRows.last : nil,
                alignments: alignments))
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
                ForEach(Array(table.headerRows.enumerated()), id: \.offset) { _, row in
                    rowView(row, table, bold: true)
                }
                if !table.headerRows.isEmpty { Divider() }
                ForEach(Array(table.bodyRows.enumerated()), id: \.offset) { _, row in
                    rowView(row, table, bold: false)
                }
                if let more = table.more {
                    Text(more)
                        .font(.footnote).foregroundStyle(.secondary)
                        .gridCellColumns(max(table.columnCount, 1))
                }
                if let total = table.totalRow {
                    Divider()
                    rowView(total, table, bold: false)
                }
            }
            .padding(12)
        }
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func rowView(_ row: [String], _ table: FigureTablePlan, bold: Bool) -> some View {
        GridRow {
            ForEach(0..<table.columnCount, id: \.self) { i in
                Text(i < row.count ? row[i] : "")
                    .font(.callout)
                    .fontWeight(bold ? .semibold : .regular)
                    .monospacedDigit()
                    .lineLimit(1)
                    .gridColumnAlignment(Self.horizontal(table.alignments[i]))
            }
        }
    }

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
