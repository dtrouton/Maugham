import Foundation

/// **A table as the HTML other apps put on the pasteboard** (report plan 7d,
/// ruling R7d-3): read the first `<table>` of what Excel, Google Sheets,
/// Numbers or a web page copied, and write a grid's display strings as a table
/// they read back. Pure and platform-free (tripwire 19): a hand-written,
/// forgiving scanner — spreadsheet HTML is not XHTML, so not `XMLParser`, and
/// not `NSAttributedString`'s HTML import, which needs AppKit/UIKit and WebKit.
public enum TableHTML {

    /// The cells of the first `<table>` in `html`, row by row, or nil when it
    /// holds no table or the table no cell.
    ///
    /// - `<tr>` is a row and `<td>`/`<th>` a cell; a cell or row left open is
    ///   closed by the next one (HTML's own rule), and `<thead>`, `<tbody>`,
    ///   `<colgroup>`, `<caption>` and text between cells are passed over.
    /// - A `colspan` cell is followed by empty cells, and a `rowspan` cell
    ///   leaves an empty cell in its column in the rows below, so every value
    ///   keeps the column it was shown in; rows are padded to the widest.
    /// - A cell's text is what a browser shows: tags inside it (`<span>`,
    ///   `<font>`, `<b>`, `<a>`…) are dropped, runs of white space are one space
    ///   and trimmed at its ends, `<br>` is a line break and so is the start of
    ///   a second `<p>` or `<div>` (Numbers wraps each cell's text in `<p>`);
    ///   as in a browser, the last `<br>` before a block's or the cell's end
    ///   shows nothing (Numbers writes an empty cell as `<p><br></p>`).
    /// - Entities are decoded: the named ones spreadsheets write, and every
    ///   `&#NNN;`/`&#xHH;`. `&nbsp;` reads as a plain space that is never
    ///   collapsed (Excel writes it for a cell's leading spaces), while `&#160;`
    ///   is kept as the no-break space it names. An unknown entity, or one
    ///   without its `;` (`&amp`, legacy HTML a browser would still decode), is
    ///   kept as written — spreadsheets always close theirs.
    /// - `<style>`, `<script>`, `<title>` and `<xml>` bodies, comments (Excel's
    ///   `<!--[if …]>…<![endif]-->` included), `<!DOCTYPE>`, `<![if …]>` and
    ///   `<?xml?>` are skipped; so are tags like `<google-sheets-html-origin>`.
    /// - A table nested in a cell gives its text to that cell.
    /// - Reading stops once the table holds more than `TableCSV.figureCellLimit`
    ///   cells (spans' empty cells counted): what comes back is already more
    ///   than any paste takes, so the paste is refused as too large rather than
    ///   a hostile `colspan` run materialising millions of cells.
    public static func rows(fromHTML html: String) -> [[String]]? {
        var reader = Reader(Array(html.unicodeScalars))
        return reader.firstTable()
    }

    /// **Rows as an HTML table** another app pastes as cells: one `<td>` per
    /// cell, `&`, `<`, `>` and `"` escaped, a line break as `<br>`, and a space
    /// a browser would collapse (leading, trailing, or after another) as
    /// `&nbsp;` — so `rows(fromHTML:)` reads back what was written, every
    /// line break as `\n`. A tab is written `&#9;`, a no-break space `&#160;`,
    /// and a cell ending in a line break gets one `<br>` more. The tab and the
    /// `&nbsp;`s are for Maugham's own reader: a browser, Numbers or Sheets
    /// shows a tab as a space (the TSV beside it on the pasteboard keeps it).
    public static func html(rows: [[String]]) -> String {
        var out = "<meta charset=\"utf-8\"><table>"
        for row in rows {
            out += "<tr>"
            for cell in row { out += "<td>" + escaped(cell) + "</td>" }
            out += "</tr>"
        }
        out += "</table>"
        return out
    }

    // MARK: - Writing

    private static func escaped(_ cell: String) -> String {
        // Line breaks first, so a `\r\n` is one break; `\r` alone is one too.
        let lines = cell.replacingOccurrences(of: "\r\n", with: "\n").split(
            separator: "\n", omittingEmptySubsequences: false
        ).flatMap { $0.split(separator: "\r", omittingEmptySubsequences: false) }
        // A browser shows nothing for a cell's last `<br>`: a cell ending in a
        // line break takes one more.
        let ending = lines.count > 1 && lines.last?.isEmpty == true ? "<br>" : ""
        return lines.map { escapedLine(String($0)) }.joined(separator: "<br>") + ending
    }

    private static func escapedLine(_ line: String) -> String {
        let scalars = Array(line.unicodeScalars)
        var out = ""
        for (i, c) in scalars.enumerated() {
            switch c {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "\t": out += "&#9;"
            case "\u{A0}": out += "&#160;"
            case " ":
                // A browser keeps a space only between two visible characters.
                let collapsible = i == 0 || i == scalars.count - 1 || scalars[i - 1] == " "
                out += collapsible ? "&nbsp;" : " "
            default: out.unicodeScalars.append(c)
            }
        }
        return out
    }
}

// MARK: - The scanner

private struct Reader {
    let s: [Unicode.Scalar]
    var i = 0

    init(_ s: [Unicode.Scalar]) { self.s = s }

    /// A tag as scanned: its lower-cased name, whether it closes, and its
    /// attributes (lower-cased names, raw values).
    struct Tag {
        var name: String
        var closing: Bool
        var attributes: [String: String]
    }

    /// What one `<` opened.
    enum Markup {
        case tag(Tag)
        /// A comment, declaration, processing instruction or raw-text element, passed over.
        case skipped
        /// No markup: a lone `<` in text, left unconsumed.
        case literal
    }

    mutating func firstTable() -> [[String]]? {
        while i < s.count {
            guard s[i] == "<" else { i += 1; continue }
            switch scanMarkup() {
            case .tag(let tag) where tag.name == "table" && !tag.closing:
                return readTable()
            case .literal: i += 1
            case .tag, .skipped: break
            }
        }
        return nil
    }

    /// From just inside the first `<table>` to its `</table>` (or the end).
    private mutating func readTable() -> [[String]]? {
        var grid = Grid()
        var nested = 0
        while i < s.count {
            let c = s[i]
            if c == "&" {
                for d in scanEntity() { grid.cell?.visible(d) }
                continue
            }
            guard c == "<" else {
                if isWhitespace(c) { grid.cell?.whitespace() } else { grid.cell?.visible(c) }
                i += 1
                continue
            }
            let tag: Tag
            switch scanMarkup() {
            case .tag(let t): tag = t
            case .skipped: continue
            case .literal:
                grid.cell?.visible("<")
                i += 1
                continue
            }
            if grid.isPastTheLimit { return grid.finish() }
            let outer = nested == 0
            switch (tag.name, tag.closing) {
            case ("table", false):
                nested += 1
                grid.cell?.block()
            case ("table", true):
                if outer { return grid.finish() }
                nested -= 1
                grid.cell?.block()
            case ("tr", false) where outer:
                grid.startRow()
            case ("tr", true) where outer:
                grid.endRow()
            case ("td", false) where outer, ("th", false) where outer:
                grid.startCell(colspan: span(tag.attributes["colspan"], max: 1_000),
                               rowspan: span(tag.attributes["rowspan"], max: 65_534))
            case ("td", true) where outer, ("th", true) where outer:
                grid.endCell()
            case ("br", _):
                grid.cell?.lineBreak()
            case ("p", _), ("div", _), ("li", _), ("tr", _):
                grid.cell?.block()        // a nested table's row breaks the line too
            case ("td", _), ("th", _):
                grid.cell?.whitespace()   // a nested table's cells: a space between them
            default:
                break
            }
        }
        return grid.finish()   // a table never closed runs to the end
    }

    private func span(_ raw: String?, max: Int) -> Int {
        guard let raw, let n = Int(raw.trimmingCharacters(in: .whitespaces)), n > 0 else { return 1 }
        return Swift.min(n, max)
    }

    private func isWhitespace(_ c: Unicode.Scalar) -> Bool {
        c == " " || c == "\t" || c == "\n" || c == "\r" || c == "\u{0C}"
    }

    private func isNameStart(_ c: Unicode.Scalar) -> Bool {
        (c >= "a" && c <= "z") || (c >= "A" && c <= "Z")
    }

    /// At a `<`: scans past one piece of markup — or, for a `<` that opens
    /// none, leaves `i` on it and answers `.literal`.
    private mutating func scanMarkup() -> Markup {
        guard i + 1 < s.count else { return .literal }
        let next = s[i + 1]
        if next == "!" {
            if matches(Self.commentOpen, at: i) {
                let body = i + Self.commentOpen.count
                if matches(Self.tagClose, at: body) {
                    i = body + 1                          // <!--> : an empty comment, as browsers read it
                } else if matches(Self.emptyCommentEnd, at: body) {
                    i = body + Self.emptyCommentEnd.count  // <!--->
                } else {
                    i = indexAfter(Self.commentClose, from: body)
                }
            } else {
                i = indexAfter(Self.tagClose, from: i + 2)     // <!DOCTYPE …>, <![if …]>, <![endif]>
            }
            return .skipped
        }
        if next == "?" { i = indexAfter(Self.tagClose, from: i + 2); return .skipped }
        let closing = next == "/"
        let nameStart = closing ? i + 2 : i + 1
        guard nameStart < s.count, isNameStart(s[nameStart]) else { return .literal }
        var j = nameStart
        var name = ""
        while j < s.count, !isWhitespace(s[j]), s[j] != ">", s[j] != "/" {
            name.unicodeScalars.append(s[j]); j += 1
        }
        name = name.lowercased()
        var attributes: [String: String] = [:]
        // Attributes, to the closing ">" (a ">" inside quotes does not close).
        while j < s.count, s[j] != ">" {
            if isWhitespace(s[j]) || s[j] == "/" { j += 1; continue }
            var attr = ""
            while j < s.count, !isWhitespace(s[j]), s[j] != "=", s[j] != ">" {
                attr.unicodeScalars.append(s[j]); j += 1
            }
            while j < s.count, isWhitespace(s[j]) { j += 1 }
            var value = ""
            if j < s.count, s[j] == "=" {
                j += 1
                while j < s.count, isWhitespace(s[j]) { j += 1 }
                if j < s.count, s[j] == "\"" || s[j] == "'" {
                    let q = s[j]; j += 1
                    while j < s.count, s[j] != q { value.unicodeScalars.append(s[j]); j += 1 }
                    if j < s.count { j += 1 }
                } else {
                    while j < s.count, !isWhitespace(s[j]), s[j] != ">" { value.unicodeScalars.append(s[j]); j += 1 }
                }
            }
            let key = attr.lowercased()
            if !key.isEmpty, attributes[key] == nil { attributes[key] = value }
        }
        // A tag the text ends inside is dropped, as a browser drops it.
        guard j < s.count else { i = s.count; return .skipped }
        i = j + 1
        if !closing, Self.rawTextElements.contains(name) {
            i = indexAfterClosing(name, from: i)
            return .skipped
        }
        return .tag(Tag(name: name, closing: closing, attributes: attributes))
    }

    private static let rawTextElements: Set<String> = ["style", "script", "title", "xml", "textarea"]
    private static let commentOpen = Array("<!--".unicodeScalars)
    private static let commentClose = Array("-->".unicodeScalars)
    private static let tagClose = Array(">".unicodeScalars)
    private static let emptyCommentEnd = Array("->".unicodeScalars)

    private func matches(_ t: [Unicode.Scalar], at k: Int) -> Bool {
        guard k + t.count <= s.count else { return false }
        for (n, c) in t.enumerated() where s[k + n] != c { return false }
        return true
    }

    /// Just past the next `t` at or after `k`; the end when there is none.
    private func indexAfter(_ t: [Unicode.Scalar], from k: Int) -> Int {
        var j = k
        while j + t.count <= s.count {
            if matches(t, at: j) { return j + t.count }
            j += 1
        }
        return s.count
    }

    /// Past `</name …>`, case-insensitively; the end when it never closes.
    private func indexAfterClosing(_ name: String, from k: Int) -> Int {
        let n = Array(name.unicodeScalars)   // already lower-case ASCII
        var j = k
        while j + 2 + n.count <= s.count {
            if s[j] == "<", s[j + 1] == "/" {
                var same = true
                for (m, c) in n.enumerated() where lowered(s[j + 2 + m]) != c { same = false; break }
                if same { return indexAfter(Self.tagClose, from: j + 2 + n.count) }
            }
            j += 1
        }
        return s.count
    }

    private func lowered(_ c: Unicode.Scalar) -> Unicode.Scalar {
        (c >= "A" && c <= "Z") ? Unicode.Scalar(c.value + 32)! : c
    }

    /// At a `&`: the character(s) it stands for, advancing past it; an
    /// unknown or unterminated entity is its own text (the `&` alone is consumed).
    private mutating func scanEntity() -> [Unicode.Scalar] {
        var j = i + 1
        var body = ""
        while j < s.count, j - i <= 32, s[j] != ";", s[j] != "&", s[j] != "<", !isWhitespace(s[j]) {
            body.unicodeScalars.append(s[j]); j += 1
        }
        guard j < s.count, s[j] == ";", !body.isEmpty, let decoded = Self.decode(body) else {
            i += 1
            return ["&"]
        }
        i = j + 1
        return decoded
    }

    private static func decode(_ body: String) -> [Unicode.Scalar]? {
        if body.hasPrefix("#") {
            let digits = body.dropFirst()
            let value: UInt32?
            if digits.first == "x" || digits.first == "X" {
                value = UInt32(digits.dropFirst(), radix: 16)
            } else {
                value = UInt32(digits, radix: 10)
            }
            guard let value else { return nil }
            // A null or a value past Unicode reads as the replacement character, as a browser does.
            guard value != 0, let scalar = Unicode.Scalar(value) else { return ["\u{FFFD}"] }
            return [scalar]
        }
        switch body {
        case "nbsp": return [" "]     // Excel's kept space; never collapsed
        case "shy": return []          // a soft hyphen shows nothing
        default: return namedEntities[body].map { [$0] }
        }
    }

    private static let namedEntities: [String: Unicode.Scalar] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'",
        "ensp": "\u{2002}", "emsp": "\u{2003}", "thinsp": "\u{2009}",
        "ndash": "\u{2013}", "mdash": "\u{2014}", "hellip": "\u{2026}", "minus": "\u{2212}",
        "lsquo": "\u{2018}", "rsquo": "\u{2019}", "sbquo": "\u{201A}",
        "ldquo": "\u{201C}", "rdquo": "\u{201D}", "bdquo": "\u{201E}",
        "laquo": "\u{AB}", "raquo": "\u{BB}", "lsaquo": "\u{2039}", "rsaquo": "\u{203A}",
        "bull": "\u{2022}", "middot": "\u{B7}", "deg": "\u{B0}", "plusmn": "\u{B1}",
        "times": "\u{D7}", "divide": "\u{F7}", "frac12": "\u{BD}", "frac14": "\u{BC}", "frac34": "\u{BE}",
        "permil": "\u{2030}", "prime": "\u{2032}", "Prime": "\u{2033}",
        "euro": "\u{20AC}", "pound": "\u{A3}", "yen": "\u{A5}", "cent": "\u{A2}", "curren": "\u{A4}",
        "copy": "\u{A9}", "reg": "\u{AE}", "trade": "\u{2122}", "sect": "\u{A7}", "para": "\u{B6}",
        "iexcl": "\u{A1}", "iquest": "\u{BF}",
        "sup1": "\u{B9}", "sup2": "\u{B2}", "sup3": "\u{B3}",
        "agrave": "\u{E0}", "aacute": "\u{E1}", "acirc": "\u{E2}", "atilde": "\u{E3}", "auml": "\u{E4}",
        "aring": "\u{E5}", "aelig": "\u{E6}", "ccedil": "\u{E7}", "egrave": "\u{E8}", "eacute": "\u{E9}",
        "ecirc": "\u{EA}", "euml": "\u{EB}", "igrave": "\u{EC}", "iacute": "\u{ED}", "icirc": "\u{EE}",
        "iuml": "\u{EF}", "ntilde": "\u{F1}", "ograve": "\u{F2}", "oacute": "\u{F3}", "ocirc": "\u{F4}",
        "otilde": "\u{F5}", "ouml": "\u{F6}", "oslash": "\u{F8}", "ugrave": "\u{F9}", "uacute": "\u{FA}",
        "ucirc": "\u{FB}", "uuml": "\u{FC}", "yacute": "\u{FD}", "yuml": "\u{FF}", "szlig": "\u{DF}",
        "Agrave": "\u{C0}", "Aacute": "\u{C1}", "Acirc": "\u{C2}", "Atilde": "\u{C3}", "Auml": "\u{C4}",
        "Aring": "\u{C5}", "AElig": "\u{C6}", "Ccedil": "\u{C7}", "Egrave": "\u{C8}", "Eacute": "\u{C9}",
        "Ecirc": "\u{CA}", "Euml": "\u{CB}", "Igrave": "\u{CC}", "Iacute": "\u{CD}", "Icirc": "\u{CE}",
        "Iuml": "\u{CF}", "Ntilde": "\u{D1}", "Ograve": "\u{D2}", "Oacute": "\u{D3}", "Ocirc": "\u{D4}",
        "Otilde": "\u{D5}", "Ouml": "\u{D6}", "Oslash": "\u{D8}", "Ugrave": "\u{D9}", "Uacute": "\u{DA}",
        "Ucirc": "\u{DB}", "Uuml": "\u{DC}", "Yacute": "\u{DD}",
    ]
}

// MARK: - The grid being read

/// The one table's rows, as its cells are read.
private struct Grid {
    var rows: [[String]] = []
    var row: [String]?
    var cell: CellText?
    /// Column → rows below still covered by a `rowspan`, counted down.
    var spans: [Int: Int] = [:]
    /// The spans the open row's cells start, live from the next row.
    var newSpans: [Int: Int] = [:]
    var sawCell = false

    mutating func startRow() {
        endRow()
        row = []
    }

    mutating func endRow() {
        endCell()
        guard var r = row else { return }
        // Columns a rowspan from above still covers, past the row's last cell.
        if let last = spans.filter({ $0.value > 0 && $0.key >= r.count }).keys.max() {
            while r.count <= last { coverIfSpanned(r.count); r.append("") }
        }
        rows.append(r)
        closedCells += r.count
        row = nil
        spans = spans.filter { $0.value > 0 }
        for (column, count) in newSpans { spans[column] = count }
        newSpans = [:]
    }

    mutating func startCell(colspan: Int, rowspan: Int) {
        endCell()
        var r = row ?? []                    // a cell with no <tr> before it opens one
        // Columns a rowspan from above covers come first.
        while (spans[r.count] ?? 0) > 0 { coverIfSpanned(r.count); r.append("") }
        row = r
        cell = CellText(column: r.count, colspan: colspan, rowspan: rowspan)
        sawCell = true
    }

    mutating func endCell() {
        guard let c = cell else { return }
        cell = nil
        row?.append(c.finished)
        for _ in 1..<c.colspan { row?.append("") }
        if c.rowspan > 1 {
            for column in c.column..<(c.column + c.colspan) { newSpans[column] = c.rowspan - 1 }
        }
    }

    private mutating func coverIfSpanned(_ column: Int) {
        if let left = spans[column], left > 0 { spans[column] = left - 1 }
    }

    /// Cells read so far, the open row's included.
    var cellCount: Int { closedCells + (row?.count ?? 0) }
    private var closedCells = 0

    /// Past what any paste takes (`TableCSV.figureCellLimit`): reading stops.
    var isPastTheLimit: Bool { cellCount > TableCSV.figureCellLimit }

    mutating func finish() -> [[String]]? {
        endRow()
        guard sawCell else { return nil }
        let width = rows.map(\.count).max() ?? 0
        // A table past the limit comes back unpadded: padding could only make it bigger.
        guard rows.count * width <= TableCSV.figureCellLimit else { return rows }
        return rows.map { $0 + Array(repeating: "", count: width - $0.count) }
    }
}

/// One cell's text, white space and line breaks as a browser shows them.
private struct CellText {
    let column: Int
    let colspan: Int
    let rowspan: Int
    private var text = ""
    /// White space was seen after visible text: one space if more follows.
    private var pendingSpace = false
    /// `<br>`s not yet written: each is a line break once more text follows.
    /// The last before a block's or the cell's end shows nothing (a browser's
    /// rule — Numbers writes an empty cell as `<p><br></p>`), the others do.
    private var pendingBreaks = 0
    /// The last pending `<br>` has been swallowed by a block boundary (a run
    /// of `</p><p>` swallows one, not one each).
    private var breakSwallowed = false
    /// A `<p>`/`<div>` boundary after visible text: a line break if more follows.
    private var pendingBlock = false
    /// At the cell's start or just after a line break: white space is dropped.
    private var atLineStart = true

    init(column: Int, colspan: Int, rowspan: Int) {
        self.column = column
        self.colspan = colspan
        self.rowspan = rowspan
    }

    /// The text, once the cell ends.
    var finished: String {
        text + String(repeating: "\n", count: breakSwallowed ? pendingBreaks : max(0, pendingBreaks - 1))
    }

    mutating func whitespace() {
        if !atLineStart { pendingSpace = true }
    }

    mutating func visible(_ c: Unicode.Scalar) {
        let breaks = pendingBreaks + (pendingBlock ? 1 : 0)
        if breaks > 0 {
            text += String(repeating: "\n", count: breaks)
        } else if pendingSpace {
            text += " "
        }
        pendingBreaks = 0
        breakSwallowed = false
        pendingBlock = false
        pendingSpace = false
        atLineStart = false
        text.unicodeScalars.append(c)
    }

    mutating func lineBreak() {
        pendingSpace = false
        pendingBreaks += 1
        breakSwallowed = false
        atLineStart = true
    }

    /// A block's start or end: a `<br>` just before it shows nothing.
    mutating func block() {
        if pendingBreaks > 0, !breakSwallowed {
            pendingBreaks -= 1
            breakSwallowed = true
        }
        pendingSpace = false
        if !text.isEmpty { pendingBlock = true }
        atLineStart = true
    }
}
