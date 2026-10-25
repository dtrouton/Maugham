import AppKit
import MaughamCore

// The read-only card drawn under a table figure's line (report plan 7a
// Task 6). `FigureThumbnailOverlay` draws it into the room the line's
// `paragraphSpacing` reserves (`FigureCardMetrics.room`), with the same
// metrics, so the card's height is exactly that room less the gap above and
// below. A decoration like the thumbnail: no attachment, no layout, no click
// (expanding the card is plan 7c).
//
// `FigureCardDrawing.plan` is pure (model + geometry + a text measurer →
// rectangles and strings), so what is drawn is asserted as values;
// `FigureCardDrawing.draw` only paints a plan.

enum FigureCardDrawing {
    /// The words a labelled card shows (ruling R7a-3), and the empty table's.
    static let removedLabel = "Figure removed"
    static let ambiguousLabel = "Two figures share this path"
    static let parkedLabel = "In Research"
    static let emptyLabel = "Empty table"
    /// The amber banner on a card whose pinned Research source has changed.
    static let pinChangedBanner = "Research has changed"

    /// The space left and right of a cell's text, inside its column.
    static let cellInset: CGFloat = 6
    /// The side of the tinted Research corner.
    static let cornerSize: CGFloat = 10

    /// "+ N more rows" (one row: "+ 1 more row").
    static func moreText(_ n: Int) -> String { n == 1 ? "+ 1 more row" : "+ \(n) more rows" }

    struct Text: Equatable {
        var string: String
        var rect: CGRect
        var alignment: CellAlignment = .left
        var bold = false
    }

    struct Plan: Equatable {
        /// The card's box: the column's left edge, the room's gap below the line.
        var card: CGRect
        /// Every shown cell, header rows first, in row then column order.
        var cells: [Text] = []
        /// Horizontal rules across the card: under the header, over the total row.
        var rules: [CGFloat] = []
        var more: Text?
        /// The amber "changed" banner, over the card's top-right corner.
        var banner: Text?
        /// The tinted Research corner (top-right triangle's bounding square).
        var corner: CGRect?
        /// A labelled card's words (removed, ambiguous, parked, empty).
        var label: Text?
    }

    /// The plan for `model` hanging under a line whose last fragment ends at
    /// `lineBottom`; nil for an image (today's thumbnail draws it).
    /// - Parameters:
    ///   - measure: a string's width in the card font, bold or not.
    static func plan(for model: FigureCardModel, lineBottom: CGFloat,
                     columnX: CGFloat, columnWidth: CGFloat, rowHeight: CGFloat,
                     measure: (String, Bool) -> CGFloat) -> Plan? {
        let padding = FigureCardMetrics.verticalPadding
        let top = lineBottom + padding
        let columnWidth = max(0, columnWidth)
        func labelled(_ words: String) -> Plan {
            let width = min(columnWidth, max(FigureThumbnailLayout.placeholderWidth,
                                             (measure(words, false) + 2 * 8).rounded(.up)))
            let card = CGRect(x: columnX, y: top, width: width,
                              height: FigureThumbnailLayout.placeholderHeight)
            return Plan(card: card, label: Text(string: words,
                                                 rect: card.insetBy(dx: 8, dy: 0)))
        }
        switch model.kind {
        case .image: return nil
        case .removed: return labelled(removedLabel)
        case .ambiguous: return labelled(ambiguousLabel)
        case .parked: return labelled(parkedLabel)
        case .table: break
        }
        guard model.shownRowCount > 0 else { return labelled(emptyLabel) }

        // Rows in drawing order: header rows, body rows short of the total,
        // "+ N more rows", then the kept total row (Task 1: the total row is
        // the last shown body row even when the table is cut short).
        let body = model.hasTotalRow ? Array(model.bodyRows.dropLast()) : model.bodyRows
        let total = model.hasTotalRow ? model.bodyRows.last : nil
        let columnCount = (model.headerRows + model.bodyRows).map(\.count).max() ?? 0

        // Each column as wide as its widest cell; the card at least as wide
        // as its banner and its "more" line, and never wider than the column
        // of text: a short fall is the last column's, an excess shrinks all.
        var widths = [CGFloat](repeating: 2 * cellInset, count: columnCount)
        for (isHeader, rows) in [(true, model.headerRows), (false, model.bodyRows)] {
            for row in rows {
                for (i, text) in row.enumerated() where i < columnCount {
                    widths[i] = max(widths[i], (measure(text, isHeader) + 2 * cellInset).rounded(.up))
                }
            }
        }
        var floor: CGFloat = 0
        if model.moreRows > 0 { floor = max(floor, measure(moreText(model.moreRows), false) + 2 * cellInset) }
        if model.pinChanged { floor = max(floor, measure(pinChangedBanner, false) + 4 * cellInset) }
        let natural = widths.reduce(0, +)
        let cardWidth = min(columnWidth, max(natural, floor.rounded(.up)))
        if natural > cardWidth, natural > 0 {
            let scale = cardWidth / natural
            widths = widths.map { ($0 * scale).rounded(.down) }
        } else if natural < cardWidth, !widths.isEmpty {
            widths[widths.count - 1] += cardWidth - natural
        }

        let shownLines = model.shownRowCount + (model.moreRows > 0 ? 1 : 0)
        let card = CGRect(x: columnX, y: top, width: cardWidth,
                          height: CGFloat(shownLines) * rowHeight)
        var plan = Plan(card: card)
        var y = top
        func addRow(_ row: [String], bold: Bool) {
            var x = columnX
            for i in 0..<columnCount {
                let text = i < row.count ? row[i] : ""
                let alignment = i < model.columnAlignments.count ? model.columnAlignments[i] : .left
                plan.cells.append(Text(
                    string: text,
                    rect: CGRect(x: x + cellInset, y: y,
                                 width: max(0, widths[i] - 2 * cellInset), height: rowHeight),
                    alignment: alignment == .automatic ? .left : alignment, bold: bold))
                x += widths[i]
            }
            y += rowHeight
        }
        model.headerRows.forEach { addRow($0, bold: true) }
        if !model.headerRows.isEmpty { plan.rules.append(y) }
        body.forEach { addRow($0, bold: false) }
        if model.moreRows > 0 {
            plan.more = Text(string: moreText(model.moreRows),
                             rect: CGRect(x: columnX + cellInset, y: y,
                                          width: max(0, cardWidth - 2 * cellInset), height: rowHeight))
            y += rowHeight
        }
        if let total {
            plan.rules.append(y)
            addRow(total, bold: false)
        }
        if model.readsResearch || model.fromResearchSource {
            plan.corner = CGRect(x: card.maxX - cornerSize, y: card.minY,
                                 width: cornerSize, height: cornerSize)
        }
        if model.pinChanged {
            let width = min(cardWidth, (measure(pinChangedBanner, false) + 2 * cellInset).rounded(.up))
            plan.banner = Text(string: pinChangedBanner,
                               rect: CGRect(x: card.maxX - width, y: card.minY,
                                            width: width, height: rowHeight),
                               alignment: .center)
        }
        return plan
    }

    // MARK: - Painting a plan

    /// Paint `plan` at `alpha` (the line's focus dim) in `font`.
    static func draw(_ plan: Plan, font: NSFont, alpha: CGFloat) {
        let bold = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
        let box = NSBezierPath(roundedRect: plan.card.insetBy(dx: 0.5, dy: 0.5), xRadius: 4, yRadius: 4)
        NSColor.secondaryLabelColor.withAlphaComponent(0.06 * alpha).setFill()
        box.fill()
        NSColor.separatorColor.withAlphaComponent(alpha).setStroke()
        box.lineWidth = 1
        box.stroke()

        if let label = plan.label {
            drawText(label, font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                     color: .secondaryLabelColor, alpha: alpha)
            return
        }
        NSGraphicsContext.saveGraphicsState()
        box.addClip()
        for y in plan.rules {
            NSColor.separatorColor.withAlphaComponent(alpha).setFill()
            CGRect(x: plan.card.minX, y: y - 0.5, width: plan.card.width, height: 1).fill()
        }
        for cell in plan.cells {
            drawText(cell, font: cell.bold ? bold : font, color: .labelColor, alpha: alpha)
        }
        if let more = plan.more {
            drawText(more, font: font, color: .secondaryLabelColor, alpha: alpha)
        }
        if let corner = plan.corner {
            let triangle = NSBezierPath()
            triangle.move(to: NSPoint(x: corner.minX, y: corner.minY))
            triangle.line(to: NSPoint(x: corner.maxX, y: corner.minY))
            triangle.line(to: NSPoint(x: corner.maxX, y: corner.maxY))
            triangle.close()
            NSColor.controlAccentColor.withAlphaComponent(0.6 * alpha).setFill()
            triangle.fill()
        }
        if let banner = plan.banner {
            NSColor.systemOrange.blended(withFraction: 0.75, of: .textBackgroundColor)?
                .withAlphaComponent(alpha).setFill()
            banner.rect.fill()
            drawText(banner, font: font, color: .labelColor, alpha: alpha)
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    private static func drawText(_ text: Text, font: NSFont, color: NSColor, alpha: CGFloat) {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        switch text.alignment {
        case .right: style.alignment = .right
        case .center: style.alignment = .center
        case .left, .automatic: style.alignment = .left
        }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: color.withAlphaComponent(alpha), .paragraphStyle: style,
        ]
        let lineHeight = (font.ascender - font.descender + font.leading).rounded(.up)
        let rect = CGRect(x: text.rect.minX, y: text.rect.midY - lineHeight / 2,
                          width: text.rect.width, height: lineHeight)
        (text.string as NSString).draw(with: rect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                                       attributes: attrs)
    }
}
