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
/// `NSRange`. It reads only the lines around the edit, never the document
/// (it runs on every keystroke).
public enum FigureLineSeparation {

    public enum Decision: Equatable, Sendable {
        /// Make this edit instead: `replacement` over the edit's own range,
        /// then the caret at `caret` in the text after it.
        case replace(range: NSRange, replacement: String, caret: Int)
        /// Make no edit (it would only glue); put the caret at `caret`.
        case refuse(caret: Int)
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
    ///   line between them — unless they already met before the edit (a
    ///   heading directly above a figure, an old file), which is left alone.
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
        guard old.range(of: "![").location != NSNotFound || r.range(of: "![").location != NSNotFound
        else { return nil }

        let prefix = text.substring(with: NSRange(location: ws, length: loc - ws))
        let suffix = text.substring(with: NSRange(location: end, length: we - end))
        let oldLines = Lines(old)
        let oldLoc = loc - ws, oldEnd = end - ws

        var edited = replacement
        var caretOffset = r.length   // where the caret lands, inside `edited`
        func window(_ middle: String) -> NSString { (prefix + middle + suffix) as NSString }

        // Text run onto a figure line's start goes on a line above it.
        if let line = oldLines.line(startingAt: oldEnd), oldLines.isFigure(line), !edited.hasSuffix("\n") {
            let w = Lines(window(edited))
            let seam = oldLoc + (edited as NSString).length
            if let at = w.line(containing: seam), !w.isFigure(at) { edited += "\n" }
        }
        // A deletion from a figure line's end keeps its line break.
        if range.length > 0, let line = oldLines.line(containing: oldLoc),
           line.contentEnd == oldLoc, oldLines.isFigure(line), !edited.hasPrefix("\n") {
            let w = Lines(window(edited))
            if let at = w.line(containing: oldLoc), !w.isFigure(at) {
                edited = "\n" + edited
                caretOffset += 1
            }
        }

        // A figure line and a non-blank line meeting at a seam.
        let w = Lines(window(edited))
        let s0 = oldLoc, s1 = oldLoc + (edited as NSString).length
        var inserts: [Int] = []
        var firstGlueUpperEnd: Int?
        for i in 0..<max(w.count - 1, 0) {
            let upper = w[i], lower = w[i + 1]
            let p = upper.contentEnd   // the newline between them
            guard p == s0 - 1 || p == s0 || p == s1 - 1 || p == s1 else { continue }
            guard !w.isBlank(upper), !w.isBlank(lower) else { continue }
            let figureBelow = w.isFigure(lower), figureAbove = w.isFigure(upper)
            guard figureBelow || figureAbove else { continue }
            // Already met before the edit? Then the edit did not glue them.
            let alreadyGlued: Bool = {
                func oldLine(of l: Lines.Line) -> Int? {
                    if l.start >= s1 { return oldLines.index(startingAt: l.start - s1 + oldEnd) }
                    if l.contentEnd <= s0 { return oldLines.index(startingAt: l.start) }
                    return nil
                }
                if figureBelow, let j = oldLine(of: lower), oldLines.isFigure(oldLines[j]),
                   j > 0, !oldLines.isBlank(oldLines[j - 1]) { return true }
                if figureAbove, let j = oldLine(of: upper), oldLines.isFigure(oldLines[j]),
                   j + 1 < oldLines.count, !oldLines.isBlank(oldLines[j + 1]) { return true }
                return false
            }()
            if alreadyGlued { continue }
            let q = (p + 1 >= s0 && p + 1 <= s1) ? p + 1 : p
            inserts.append(q - s0)
            if firstGlueUpperEnd == nil { firstGlueUpperEnd = p }
        }

        guard edited != replacement || !inserts.isEmpty else { return nil }
        let caret = caretOffset + inserts.filter { $0 < caretOffset }.count
        let final = NSMutableString(string: edited)
        for offset in inserts.sorted(by: >) { final.insert("\n", at: offset) }
        let result = final as String

        if result == text.substring(with: range) {
            // The edit would only have removed the break: refuse it, and put
            // the caret at the end of the paragraph above, where a Backspace
            // was heading.
            return .refuse(caret: ws + oldLines.lastNonBlankEnd(atOrBefore: oldLoc, otherwise: oldLoc))
        }
        return .replace(range: range, replacement: result, caret: loc + caret)
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
        struct Line { let start: Int; let contentEnd: Int }
        let text: NSString
        private let lines: [Line]

        init(_ text: NSString) {
            self.text = text
            var out: [Line] = []
            var start = 0
            let n = text.length
            while true {
                let nl = start < n ? text.range(of: "\n", range: NSRange(location: start, length: n - start)).location
                                   : NSNotFound
                if nl == NSNotFound { out.append(Line(start: start, contentEnd: n)); break }
                out.append(Line(start: start, contentEnd: nl))
                start = nl + 1
            }
            lines = out
        }

        var count: Int { lines.count }
        subscript(i: Int) -> Line { lines[i] }

        func content(_ line: Line) -> String {
            text.substring(with: NSRange(location: line.start, length: line.contentEnd - line.start))
        }
        func isBlank(_ line: Line) -> Bool {
            content(line).trimmingCharacters(in: .whitespaces).isEmpty
        }
        func isFigure(_ line: Line) -> Bool { FigureLineSeparation.isFigureLine(content(line)) }

        func index(startingAt location: Int) -> Int? { lines.firstIndex { $0.start == location } }
        func line(startingAt location: Int) -> Line? { index(startingAt: location).map { lines[$0] } }
        func line(containing location: Int) -> Line? {
            lines.first { location >= $0.start && location <= $0.contentEnd }
        }
        /// The end of the last non-blank line ending at or before `location`.
        func lastNonBlankEnd(atOrBefore location: Int, otherwise: Int) -> Int {
            lines.last { $0.contentEnd <= location && !isBlank($0) }?.contentEnd ?? otherwise
        }
    }
}
