import Foundation

/// **A figure line always stands as its own paragraph.** An image is a figure
/// only alone in its paragraph (`ManuscriptBlocks`' rule, and pandoc's), so a
/// line of text glued directly above or below a figure line turns the figure
/// into an inline image: the card goes, and Publish prints a picture in a
/// sentence. This is the one rule the editor applies to each edit before it
/// lands: an edit that would glue text to a figure line gets the paragraph
/// break added inside the same edit, and an edit that would only remove the
/// break (a Backspace or Delete over the one blank line) is refused.
///
/// Pure and platform-free (tripwire 19): positions are the text's UTF-16, as
/// `NSRange`. It runs on every keystroke, so it reads only the lines around
/// the edit, and only where one holds `![` does it search the text above for
/// ``` fences (`isInCode`).
public enum FigureLineSeparation {

    public enum Decision: Equatable, Sendable {
        /// Make this edit instead: `replacement` over the edit's own range,
        /// then the caret at `caret` in the text after it.
        case replace(range: NSRange, replacement: String, caret: Int)
        /// Make no edit (it would only glue). `caret` is where the caret goes
        /// (the end of the paragraph above, where a Backspace was heading),
        /// or nil to leave it where it is — always when the line above is a
        /// figure line, so a held key never lands on it and eats its label.
        case refuse(caret: Int?)
    }

    /// What to do with replacing `range` of `text` by `replacement`, or nil
    /// when the edit leaves every figure line it touches separated (the
    /// common case: make it as it is).
    ///
    /// The rule, at the edit's two seams only (what the writer typed or
    /// pasted inside itself is left as written):
    /// - text inserted at a figure line's very start that would run onto it
    ///   goes on a line of its own above it;
    /// - a deletion from a figure line's end that would pull the next line
    ///   onto it keeps the line break;
    /// - a figure line and a non-blank line meeting at a seam get a blank
    ///   line between them — unless that same line already met it before the
    ///   edit (a heading directly above a figure, an old file), which is left
    ///   alone; a line the edit made is never "already" there.
    ///
    /// Lines end at any line terminator (`\n`, `\r\n`, `\r`, U+2028…); a
    /// break it adds is the text's own `\r\n` or `\r`, otherwise `\n`.
    /// Nothing in code is touched (`isInCode`).
    public static func decide(text: NSString, range: NSRange, replacement: String) -> Decision? {
        let r = replacement as NSString
        guard range.location >= 0, NSMaxRange(range) <= text.length,
              range.length > 0 || r.length > 0 else { return nil }
        let loc = range.location, end = NSMaxRange(range)

        // The window: the line before the edit's first line through the line
        // after its last, so every line a seam can touch is inside it.
        let firstLine = text.lineRange(for: NSRange(location: loc, length: 0))
        let ws = firstLine.location > 0
            ? text.lineRange(for: NSRange(location: firstLine.location - 1, length: 0)).location : 0
        var we = NSMaxRange(text.lineRange(for: NSRange(location: end, length: 0)))
        if we < text.length { we = NSMaxRange(text.lineRange(for: NSRange(location: we, length: 0))) }
        we = max(we, end)
        let old = text.substring(with: NSRange(location: ws, length: we - ws)) as NSString
        guard old.range(of: "![").location != NSNotFound || r.range(of: "![").location != NSNotFound,
              !isInCode(lineAt: loc, in: text)
        else { return nil }

        let prefix = text.substring(with: NSRange(location: ws, length: loc - ws))
        let suffix = text.substring(with: NSRange(location: end, length: we - end))
        let oldLines = Lines(old)
        let oldLoc = loc - ws, oldEnd = end - ws
        let eol = oldLines.lineEnding ?? Lines(r).lineEnding ?? "\n"
        let eolLength = (eol as NSString).length

        var edited = replacement
        var caretOffset = r.length   // where the caret lands, inside `edited`
        func window(_ middle: String) -> NSString { (prefix + middle + suffix) as NSString }

        // Text run onto a figure line's start goes on a line above it.
        if let line = oldLines.line(startingAt: oldEnd), oldLines.isFigure(line), edited.last?.isNewline != true {
            let w = Lines(window(edited))
            let seam = oldLoc + (edited as NSString).length
            if let at = w.line(containing: seam), !w.isFigure(at) { edited += eol }
        }
        // A deletion from a figure line's end keeps its line break.
        if range.length > 0, let line = oldLines.line(containing: oldLoc),
           line.contentEnd == oldLoc, oldLines.isFigure(line), edited.first?.isNewline != true {
            let w = Lines(window(edited))
            if let at = w.line(containing: oldLoc), !w.isFigure(at) {
                edited = eol + edited
                caretOffset += eolLength
            }
        }

        // A figure line and a non-blank line meeting at a seam.
        let w = Lines(window(edited))
        let s0 = oldLoc, s1 = oldLoc + (edited as NSString).length
        // The line before the edit that `l` is, or nil when the edit made it:
        // a line beginning before the edit is the old line beginning there; one
        // beginning after it, the old one beginning there; one beginning
        // inside it, the old line its untouched end belongs to.
        func oldIndex(of l: Lines.Line) -> Int? {
            if l.start < s0 { return oldLines.index(startingAt: l.start) }
            if l.start >= s1 { return oldLines.index(startingAt: l.start - s1 + oldEnd) }
            if l.contentEnd >= s1 { return oldLines.index(endingAt: l.contentEnd - s1 + oldEnd) }
            return nil
        }
        var inserts: [Int] = []
        for i in 0..<max(w.count - 1, 0) {
            let upper = w[i], lower = w[i + 1]
            let c = upper.contentEnd, e = upper.end   // the terminator between them
            guard (c <= s0 && s0 <= e) || (c <= s1 && s1 <= e) else { continue }
            guard !w.isBlank(upper), !w.isBlank(lower) else { continue }
            let figureBelow = w.isFigure(lower), figureAbove = w.isFigure(upper)
            guard figureBelow || figureAbove else { continue }
            // The same two lines already met before the edit? Then it did not glue them.
            let u = oldIndex(of: upper), l = oldIndex(of: lower)
            if let u, let l, l == u + 1, !oldLines.isBlank(oldLines[u]), !oldLines.isBlank(oldLines[l]),
               (figureBelow && oldLines.isFigure(oldLines[l])) || (figureAbove && oldLines.isFigure(oldLines[u])) {
                continue
            }
            let q: Int
            if e >= s0 && e <= s1 { q = e } else if c >= s0 && c <= s1 { q = c } else { continue }
            inserts.append(q - s0)
        }

        guard edited != replacement || !inserts.isEmpty else { return nil }
        let caret = caretOffset + eolLength * inserts.filter { $0 < caretOffset }.count
        let final = NSMutableString(string: edited)
        for offset in inserts.sorted(by: >) { final.insert(eol, at: offset) }
        let result = final as String

        if result == text.substring(with: range) {
            // The edit would only have removed the break: refuse it, the caret
            // to the end of the paragraph above — or left where it is when
            // that line is a figure line.
            guard let above = oldLines.lastNonBlank(atOrBefore: oldLoc), !oldLines.isFigure(above)
            else { return .refuse(caret: nil) }
            return .refuse(caret: ws + above.contentEnd)
        }
        return .replace(range: range, replacement: result, caret: loc + caret)
    }

    /// True when the line holding `location` is code, where the rule never
    /// applies and a figure line is not one: inside a ``` fence (the fence
    /// lines included, counted from the text's start as the parser counts
    /// them), or indented as code (four spaces or a tab). `ManuscriptChecks`
    /// asks the same.
    public static func isInCode(lineAt location: Int, in text: NSString) -> Bool {
        guard location >= 0, location <= text.length else { return false }
        var start = 0, end = 0, contentsEnd = 0
        text.getLineStart(&start, end: &end, contentsEnd: &contentsEnd,
                          for: NSRange(location: location, length: 0))
        let line = text.substring(with: NSRange(location: start, length: contentsEnd - start))
        if isIndentedCode(line) || line.trimmingCharacters(in: .whitespaces).hasPrefix("```") { return true }
        var fences = 0, search = 0
        while search < start {
            let found = text.range(of: "```", range: NSRange(location: search, length: start - search))
            guard found.location != NSNotFound else { break }
            var ls = 0, le = 0, lc = 0
            text.getLineStart(&ls, end: &le, contentsEnd: &lc, for: NSRange(location: found.location, length: 0))
            if text.substring(with: NSRange(location: ls, length: found.location - ls))
                .trimmingCharacters(in: .whitespaces).isEmpty { fences += 1 }
            search = max(le, NSMaxRange(found))
        }
        return fences % 2 == 1
    }

    /// A line indented as code: four spaces or a tab.
    static func isIndentedCode(_ line: String) -> Bool {
        line.hasPrefix("    ") || line.hasPrefix("\t")
    }

    /// True when `line` (one line, no terminator) alone reads as a figure:
    /// `![caption](path)` with an optional `{#…}` label, by
    /// `ManuscriptBlocks.parse` — the rule the editor's figure tokens and
    /// Publish read a figure line by.
    public static func isFigureLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("![") else { return false }
        if case .figure? = ManuscriptBlocks.parse(trimmed).first?.block { return true }
        return false
    }

    // MARK: - Lines of a small window

    struct Lines {
        /// One line: its content `start..<contentEnd`, its terminator
        /// `contentEnd..<end` (empty on the last line).
        struct Line: Equatable { let start: Int; let contentEnd: Int; let end: Int }
        let text: NSString
        private let lines: [Line]

        /// Split at every line terminator NSString knows (`\n`, `\r\n`, `\r`,
        /// U+0085, U+2028, U+2029); a text ending in one has an empty last line.
        init(_ text: NSString) {
            self.text = text
            var out: [Line] = []
            var start = 0
            let n = text.length
            while start < n {
                var s = 0, e = 0, c = 0
                text.getLineStart(&s, end: &e, contentsEnd: &c, for: NSRange(location: start, length: 0))
                out.append(Line(start: s, contentEnd: c, end: e))
                start = e
            }
            if out.last.map({ $0.end > $0.contentEnd }) ?? true {
                out.append(Line(start: n, contentEnd: n, end: n))
            }
            lines = out
        }

        var count: Int { lines.count }
        subscript(i: Int) -> Line { lines[i] }

        /// The break to add: the first terminator's when it is `\r\n` or
        /// `\r`, `\n` for any other; nil when there is none.
        var lineEnding: String? {
            guard let line = lines.first(where: { $0.end > $0.contentEnd }) else { return nil }
            let t = text.substring(with: NSRange(location: line.contentEnd, length: line.end - line.contentEnd))
            return t == "\r\n" || t == "\r" ? t : "\n"
        }

        func content(_ line: Line) -> String {
            text.substring(with: NSRange(location: line.start, length: line.contentEnd - line.start))
        }
        func isBlank(_ line: Line) -> Bool {
            content(line).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        func isFigure(_ line: Line) -> Bool {
            let c = content(line)
            return !FigureLineSeparation.isIndentedCode(c) && FigureLineSeparation.isFigureLine(c)
        }

        func index(startingAt location: Int) -> Int? { lines.firstIndex { $0.start == location } }
        func index(endingAt contentEnd: Int) -> Int? { lines.firstIndex { $0.contentEnd == contentEnd } }
        func line(startingAt location: Int) -> Line? { index(startingAt: location).map { lines[$0] } }
        func line(containing location: Int) -> Line? {
            lines.first { location >= $0.start && location <= $0.contentEnd }
        }
        /// The last non-blank line ending at or before `location`.
        func lastNonBlank(atOrBefore location: Int) -> Line? {
            lines.last { $0.contentEnd <= location && !isBlank($0) }
        }
    }
}
