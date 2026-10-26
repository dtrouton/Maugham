import Foundation

/// **Cells copied from a spreadsheet, as rows** (report foundations plan 3b
/// Task 5): what Excel, Numbers and Google Sheets put on the pasteboard as
/// tab-separated text, read by Excel's quoting rules. Its one
/// reader, the grid sheet's Paste Cells, is retired (report plan 7b); it
/// stays in Core so a later reader, phone or MCP, shares it (tripwire 19).
public enum TableClipboard {
    /// The rows of `text`, each a list of cells, by Excel's tab-separated rules:
    ///
    /// - a tab ends a cell; `\r\n`, `\r` or `\n` ends a row, and the break
    ///   after the last row adds no empty one;
    /// - a cell that OPENS with `"` is quoted: up to the next lone `"` it may
    ///   hold tabs and line breaks, and `""` is one `"`;
    /// - a `"` anywhere else is just a character.
    ///
    /// Nothing copied is dropped: text after a closing quote joins the cell,
    /// and a quote never closed runs to the end. Rows come back as copied —
    /// a ragged row is not padded — and a cell's line breaks are kept (the
    /// table writes them as spaces, `TableText.singleLine`).
    ///
    /// `quoting: false` reads the same rows without the quote rule — for text
    /// that did not come as a spreadsheet's tab-separated flavour, where a
    /// leading `"` is the writer's own character and is kept.
    public static func rows(fromTabSeparated text: String, quoting: Bool = true) -> [[String]] {
        let scalars = Array(text.unicodeScalars)
        var rows: [[String]] = []
        var row: [String] = []
        var cell = String.UnicodeScalarView()
        var i = 0
        var atCellStart = true
        // Whether anything of the current row has been read: a break with
        // nothing before it is still a row (an empty line), but the end of
        // the text straight after a break is not.
        var rowOpen = false

        func endCell() {
            row.append(String(cell))
            cell = String.UnicodeScalarView()
            atCellStart = true
        }
        func endRow() {
            endCell()
            rows.append(row)
            row = []
            rowOpen = false
        }

        while i < scalars.count {
            let c = scalars[i]
            if quoting && atCellStart && c == quote {
                atCellStart = false
                rowOpen = true
                i += 1
                while i < scalars.count {
                    if scalars[i] == quote {
                        if i + 1 < scalars.count && scalars[i + 1] == quote {
                            cell.append(quote)
                            i += 2
                            continue
                        }
                        i += 1                       // the closing quote
                        break
                    }
                    cell.append(scalars[i])
                    i += 1
                }
                continue
            }
            switch c {
            case tab:
                rowOpen = true
                endCell()
                i += 1
            case carriageReturn:
                endRow()
                i += (i + 1 < scalars.count && scalars[i + 1] == lineFeed) ? 2 : 1
            case lineFeed:
                endRow()
                i += 1
            default:
                cell.append(c)
                atCellStart = false
                rowOpen = true
                i += 1
            }
        }
        if rowOpen { endRow() }
        return rows
    }
}

private let quote: Unicode.Scalar = "\""
private let tab: Unicode.Scalar = "\t"
private let carriageReturn: Unicode.Scalar = "\r"
private let lineFeed: Unicode.Scalar = "\n"
