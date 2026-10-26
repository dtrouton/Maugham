import Foundation

/// **One pipe table as text, and the one formatter that writes it** (report
/// foundations plan 3a Task 5). The editor's Tab, Return and leave-the-table
/// tidy write through `formatted()`; Convert to Table Figure reads it, and so
/// may publishing, the phone or MCP (tripwire 19: one implementation, here).
///
/// It reads through `ManuscriptBlocks.parse` — the reader publishing and the
/// index use — so a cell is exactly what the book sees as a cell. In
/// particular Core's row splitter does not know code spans: a `|` inside
/// backticks splits the cell unless it is written `\|`, here as everywhere.
///
/// A short body row is padded to the header's column count with empty cells;
/// a long one keeps every cell (no text the writer typed is dropped), so
/// `TableText(parsing: t.formatted()) == t` holds for every parsed `t`.
public struct TableText: Equatable, Sendable {
    /// The header row's cells, unescaped (`\|` read as `|`).
    public var header: [String]
    /// One per header column, from the delimiter row.
    public var alignments: [TableAlignment]
    /// The body rows' cells, unescaped.
    public var rows: [[String]]
    /// The `Table: …` line's text without its label; nil with no caption line.
    public var caption: String?
    /// The caption line's trailing `{#tbl:…}`.
    public var label: ManuscriptLabel?

    public init(header: [String], alignments: [TableAlignment], rows: [[String]],
                caption: String? = nil, label: ManuscriptLabel? = nil) {
        self.header = header
        self.alignments = alignments
        self.rows = rows
        self.caption = caption
        self.label = label
    }

    /// The table `block` holds; nil unless the block is exactly one table
    /// (with or without its caption line) and nothing else.
    public init?(parsing block: String) {
        let parsed = ManuscriptBlocks.parse(block)
        guard parsed.count == 1,
              case .table(let header, let alignments, let rows, let caption, let label) = parsed[0].block,
              !header.isEmpty
        else { return nil }
        self.header = header
        self.alignments = alignments
        self.rows = rows.map { row in
            row.count >= header.count ? row : row + Array(repeating: "", count: header.count - row.count)
        }
        self.caption = caption
        self.label = label
    }

    // MARK: - Formatting

    /// The table with column-aligned pipes: every row `| cell | cell |`, each
    /// cell left-justified and padded to its column's width (at least 3, so
    /// `:-:` fits); the delimiter row written from `alignments` (`:--`, `:-:`,
    /// `--:`, `---`); a `|` in a cell escaped `\|` and a line break written as a
    /// space; then the caption line, `Table: caption {#tbl:x}`. Never a blank
    /// line, so the table stays one op-log paragraph.
    ///
    /// **Display width is the grapheme (`Character`) count.** That is exact
    /// for Latin, Cyrillic, Greek and emoji sequences in a monospaced sense,
    /// and an approximation everywhere else: a CJK ideograph or a full-width
    /// form is one grapheme but two columns, so a table holding them lines up
    /// by count rather than by eye. No East Asian width table is consulted.
    public func formatted() -> String {
        let escapedHeader = header.map(Self.escape)
        let escapedRows = rows.map { $0.map(Self.escape) }
        let columns = max(header.count, escapedRows.map(\.count).max() ?? 0)
        var widths = Array(repeating: Self.minimumWidth, count: columns)
        for row in [escapedHeader] + escapedRows {
            for (i, cell) in row.enumerated() { widths[i] = max(widths[i], cell.count) }
        }

        func line(_ cells: [String], count: Int) -> String {
            let padded = (0..<count).map { i -> String in
                let cell = i < cells.count ? cells[i] : ""
                return cell + String(repeating: " ", count: widths[i] - cell.count)
            }
            return "| " + padded.joined(separator: " | ") + " |"
        }

        var lines = [line(escapedHeader, count: header.count)]
        let delimiter = (0..<header.count).map { i -> String in
            let w = widths[i]
            switch i < alignments.count ? alignments[i] : .none {
            case .none: return String(repeating: "-", count: w)
            case .leading: return ":" + String(repeating: "-", count: w - 1)
            case .center: return ":" + String(repeating: "-", count: w - 2) + ":"
            case .trailing: return String(repeating: "-", count: w - 1) + ":"
            }
        }
        lines.append("| " + delimiter.joined(separator: " | ") + " |")
        for row in escapedRows { lines.append(line(row, count: max(header.count, row.count))) }
        if let captionLine { lines.append(captionLine) }
        return lines.joined(separator: "\n")
    }

    /// `Table: caption {#tbl:x}`; `Table: {#tbl:x}` for a label with no
    /// caption (nil or empty — a label can be set without a caption,
    /// and dropping it would orphan every `@tbl:x`); nil with neither, which
    /// no `Table:` line could read back. A line break in the caption is a
    /// space (`singleLine`).
    private var captionLine: String? {
        let text = Self.singleLine(caption ?? "")
        guard !(text.isEmpty && label == nil) else { return nil }
        let parts = [text, label.map { "{#\($0.reference)}" } ?? ""].filter { !$0.isEmpty }
        return "Table: " + parts.joined(separator: " ")
    }

    private static let minimumWidth = 3

    /// `text` with every line break (`\r\n`, `\r`, `\n`) written as one space.
    /// A cell or caption is one line of the table: a break would end the row,
    /// and a doubled one would split the table into two op-log paragraphs.
    public static func singleLine(_ text: String) -> String {
        guard text.contains(where: \.isNewline) else { return text }
        return text.replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
    }

    private static func escape(_ cell: String) -> String {
        singleLine(cell).replacingOccurrences(of: "|", with: "\\|")
    }

    // MARK: - Cells and offsets

    /// The cell holding UTF-16 offset `utf16Offset` of `block` (formatted or
    /// not): row 0 is the header, row 1 the first body row. nil on the
    /// delimiter row, on the caption line, or when `block` is not a table. On
    /// a pipe, the offset belongs to the cell before it; before a row's first
    /// pipe, to its first cell; after its last, to its last.
    public static func cell(at utf16Offset: Int, in block: String) -> (row: Int, column: Int)? {
        guard let table = TableText(parsing: block) else { return nil }
        let ns = block as NSString
        let lines = lineRanges(in: ns)
        guard let lineIndex = lines.firstIndex(where: {
            utf16Offset >= $0.location && utf16Offset <= NSMaxRange($0)
        }) else { return nil }
        let row: Int
        switch lineIndex {
        case 0: row = 0
        case 1: return nil
        case let i where i - 1 <= table.rows.count: row = i - 1
        default: return nil                                   // the caption line
        }
        let line = lines[lineIndex]
        let pipes = pipeLocations(in: line, ns)
        let cellCount = row == 0 ? table.header.count : table.rows[row - 1].count
        var column = pipes.filter { $0 < utf16Offset }.count
        if leadsWithPipe(line, ns) { column -= 1 }
        return (row, max(0, min(column, max(0, cellCount - 1))))
    }

    /// The UTF-16 offset in `formatted` where cell (`row`, `column`)'s text
    /// starts (row 0 is the header). An empty cell's text starts one space
    /// after its opening pipe. A row or column past the end clamps to the
    /// last one.
    public static func offset(ofCell row: Int, _ column: Int, in formatted: String) -> Int {
        textRange(ofCell: row, column, in: formatted).location
    }

    /// Cell (`row`, `column`)'s text in `formatted` (or any table block),
    /// without the spaces around it: what Tab selects. Empty for an empty
    /// cell, at `offset(ofCell:_:in:)`.
    public static func textRange(ofCell row: Int, _ column: Int, in formatted: String) -> NSRange {
        let ns = formatted as NSString
        let lines = lineRanges(in: ns)
        guard !lines.isEmpty else { return NSRange(location: 0, length: 0) }
        let bodyLines = TableText(parsing: formatted).map { $0.rows.count } ?? max(0, lines.count - 2)
        let lineIndex = row <= 0 ? 0 : min(row, bodyLines) + 1
        guard lineIndex < lines.count else { return NSRange(location: ns.length, length: 0) }
        let line = lines[lineIndex]
        var bounds = pipeLocations(in: line, ns)
        // Cell spans run between consecutive pipes; a row without its outer
        // pipes is bounded by the line's own ends.
        if !leadsWithPipe(line, ns) { bounds.insert(line.location - 1, at: 0) }
        if bounds.count < 2 || !trailsWithPipe(line, ns) { bounds.append(NSMaxRange(line)) }
        let spans = bounds.count - 1
        guard spans > 0 else { return NSRange(location: line.location, length: 0) }
        let i = max(0, min(column, spans - 1))
        let start = bounds[i] + 1
        let end = bounds[i + 1]
        var lo = start, hi = end
        while lo < hi, isSpace(ns.character(at: lo)) { lo += 1 }
        while hi > lo, isSpace(ns.character(at: hi - 1)) { hi -= 1 }
        if lo == hi { return NSRange(location: min(start + 1, end), length: 0) }
        return NSRange(location: lo, length: hi - lo)
    }

    // MARK: - Lines and pipes

    /// The `"\n"`-separated lines of `ns`, each without its newline.
    private static func lineRanges(in ns: NSString) -> [NSRange] {
        var out: [NSRange] = []
        var start = 0
        for i in 0..<ns.length where ns.character(at: i) == newline {
            out.append(NSRange(location: start, length: i - start))
            start = i + 1
        }
        out.append(NSRange(location: start, length: ns.length - start))
        return out
    }

    /// The unescaped `|`s of `line`, as `MarkdownBlockParser.splitTableRow`
    /// splits them (`\|` is a literal pipe).
    private static func pipeLocations(in line: NSRange, _ ns: NSString) -> [Int] {
        var out: [Int] = []
        var i = line.location
        let end = NSMaxRange(line)
        while i < end {
            let c = ns.character(at: i)
            if c == backslash, i + 1 < end, ns.character(at: i + 1) == pipe { i += 2; continue }
            if c == pipe { out.append(i) }
            i += 1
        }
        return out
    }

    private static func leadsWithPipe(_ line: NSRange, _ ns: NSString) -> Bool {
        var i = line.location
        while i < NSMaxRange(line), isSpace(ns.character(at: i)) { i += 1 }
        return i < NSMaxRange(line) && ns.character(at: i) == pipe
    }

    private static func trailsWithPipe(_ line: NSRange, _ ns: NSString) -> Bool {
        var i = NSMaxRange(line)
        while i > line.location, isSpace(ns.character(at: i - 1)) { i -= 1 }
        guard i > line.location, ns.character(at: i - 1) == pipe else { return false }
        return !(i - 2 >= line.location && ns.character(at: i - 2) == backslash)
    }

    private static func isSpace(_ c: unichar) -> Bool { c == space || c == tab }
}

private let newline = unichar(UInt8(ascii: "\n"))
private let pipe = unichar(UInt8(ascii: "|"))
private let backslash = unichar(UInt8(ascii: "\\"))
private let space = unichar(UInt8(ascii: " "))
private let tab = unichar(UInt8(ascii: "\t"))
