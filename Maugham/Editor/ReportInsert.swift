import Foundation
import MaughamCore

/// **What the Insert menu writes, and where** (plan 3a Task 4, R-3a-6; a
/// figure line's placement, `blockEdit`). Pure text, so every rule is pinned
/// without a view (`ReportInsertTests`). The coordinator turns an `Edit` into one Route A
/// replace (`EditorCoordinator.applyCommandEdit`), which is one ⌘Z step.
///
/// A "paragraph" here is the op log's: a blank-line-delimited block, the way
/// `ParagraphParser` splits text. A whitespace-only line counts as blank.
enum ReportInsert {
    /// One replace in the document's text: `replacedRange` and `selection` are
    /// UTF-16 ranges in the WHOLE text (the selection is in the text after the
    /// replace).
    struct Edit: Equatable {
        let replacedRange: NSRange
        let replacement: String
        let selection: NSRange
    }

    // MARK: - Labels

    /// Every label `text` DEFINES: a heading's, a table caption's or a
    /// figure's trailing `{#kind:name}`.
    static func definedLabels(in text: String) -> Set<ManuscriptLabel> {
        Set(ManuscriptBlocks.parse(text).compactMap { label(of: $0.block) })
    }

    /// The labels every publishable manuscript piece in `structure` defines
    /// except `docId`'s, each read through `text` (live-or-derived display
    /// text; nil skips it). Screenplays and reference pieces define none here.
    /// A synchronous walk: `ReferenceIndexHost.labelsDefined(excluding:)`
    /// answers with it only while no index build has published (whole-branch
    /// review I1); after that the cached index answers.
    static func labelsElsewhere(in structure: [StructureItem], excluding docId: String,
                                text: (StructureItem, String) -> String?) -> Set<ManuscriptLabel> {
        ReferenceIndex.build(structure: structure, research: [],
                             text: { item in item.path.flatMap { text(item, $0) } },
                             words: .english)
            .labelsDefined(excluding: docId)
    }

    /// `block` (text with no blank line: one op-log paragraph) on a block of
    /// its own at `location`, `selectionInBlock` selected — the placement rule
    /// every figure line takes (Insert Figure…, Insert ▸ Table). Mid-line, it
    /// splits the paragraph; at a line's edge it adds only the blank lines it
    /// needs.
    /// Spaces and tabs touching the caret on its line are absorbed. Inside a
    /// table (any range of `tableBlocks`) it goes after that table's paragraph;
    /// on a figure line, after that line (`endOfFigureLine`).
    static func blockEdit(in text: String, at location: Int, tableBlocks: [NSRange],
                          block: String, selectionInBlock: NSRange) -> Edit {
        let ns = text as NSString
        var at = max(0, min(location, ns.length))
        if let enclosing = tableBlocks.first(where: {
            at >= $0.location && at <= NSMaxRange($0) && $0.length > 0
        }) {
            at = NSMaxRange(paragraphRange(containing: enclosing.location, in: ns))
        }
        // On a figure line it goes after that line, never splitting it into
        // two lines that are no longer a figure (report plan 8b Task 3 review).
        at = endOfFigureLine(containing: at, in: ns) ?? at

        let line = ns.lineRange(for: NSRange(location: at, length: 0))
        let lineEnd = contentEnd(ofLine: line, in: ns)
        var start = at
        while start > line.location, isSpaceOrTab(ns.character(at: start - 1)) { start -= 1 }
        var end = at
        while end < lineEnd, isSpaceOrTab(ns.character(at: end)) { end += 1 }

        let before: String
        if start > line.location {
            before = "\n\n"                                  // text before on this line
        } else if line.location == 0 || isBlankLine(endingBefore: line.location, in: ns) {
            before = ""                                      // already a block edge
        } else {
            before = "\n"                                    // close the paragraph above
        }

        let after: String
        if end < lineEnd {
            after = "\n\n"                                   // text after on this line
        } else if lineEnd >= ns.length || isBlankLine(startingAt: NSMaxRange(line), in: ns) {
            after = ""                                       // end of text, or a blank line below
        } else {
            after = "\n"                                     // open a blank line before the next
        }

        let prefix = (before as NSString).length
        return Edit(
            replacedRange: NSRange(location: start, length: end - start),
            replacement: before + block + after,
            selection: NSRange(location: start + prefix + selectionInBlock.location,
                               length: selectionInBlock.length))
    }

    /// The end of `location`'s line (before its line break) when that line
    /// reads as a figure line (`ManuscriptBlocks.parse`) and `location` is
    /// inside it — past its first character, before its end; nil otherwise
    /// (at either edge the placement already keeps the line whole).
    static func endOfFigureLine(containing location: Int, in ns: NSString) -> Int? {
        let line = ns.lineRange(for: NSRange(location: location, length: 0))
        let end = contentEnd(ofLine: line, in: ns)
        let raw = ns.substring(with: NSRange(location: line.location, length: end - line.location))
        let lead = (String(raw.prefix { $0 == " " || $0 == "\t" }) as NSString).length
        guard location > line.location + lead, location < end else { return nil }
        let content = raw.trimmingCharacters(in: .whitespaces)
        guard case .figure? = ManuscriptBlocks.parse(content).first?.block else { return nil }
        return end
    }

    /// `block` in place of the whole lines `range` (Convert to Table Figure: a
    /// pipe table's rows and `Table:` line), standing as a block of its own —
    /// the figure-line grammar reads a figure only from a one-line paragraph.
    /// A line break goes before `block` when the line above `range` is not
    /// blank, and after it when the line below is not, so text that touched
    /// the replaced lines (prose right under a table, which the table did not
    /// claim) stays out of `block`'s paragraph (whole-branch review I1). The
    /// selection is a caret right after `block`.
    static func blockReplacement(of range: NSRange, in text: String, with block: String) -> Edit {
        let ns = text as NSString
        let before = isBlankLine(endingBefore: range.location, in: ns) ? "" : "\n"
        let end = NSMaxRange(range)
        let below = end < ns.length
            ? NSMaxRange(ns.lineRange(for: NSRange(location: end, length: 0))) : ns.length
        let after = isBlankLine(startingAt: below, in: ns) ? "" : "\n"
        let caret = range.location + (before as NSString).length + (block as NSString).length
        return Edit(replacedRange: range, replacement: before + block + after,
                    selection: NSRange(location: caret, length: 0))
    }

    // MARK: - R-3a-6 Insert Footnote

    /// `[^n]` at `caret`, and a `[^n]: ` definition paragraph after
    /// `paragraph`, separated by one blank line, as ONE replace of
    /// `[caret, end of paragraph)`. Ranges are relative to the paragraph; the
    /// caret lands at the end of the definition. n is
    /// `lowestFreeFootnoteLabel(existing: existingLabels)`. A caret at or past
    /// the start of its line's trailing `{#…}` block (a heading's, a caption's)
    /// puts the ref before the block and the spaces before it, so the label
    /// stays the line's last thing.
    static func footnote(in paragraph: String, caret: Int, existingLabels: Set<String>)
        -> (replacement: String, replacedRange: NSRange, caret: NSRange)
    {
        let ns = paragraph as NSString
        var at = max(0, min(caret, ns.length))
        let line = ns.lineRange(for: NSRange(location: at, length: 0))
        let content = NSRange(location: line.location,
                              length: contentEnd(ofLine: line, in: ns) - line.location)
        if let block = MarkdownTokenizer.trailingAttributeBlock(in: ns, line: content) {
            var start = block.location
            while start > content.location, isSpaceOrTab(ns.character(at: start - 1)) { start -= 1 }
            if at > start { at = start }
        }
        let label = lowestFreeFootnoteLabel(existing: existingLabels)
        let tail = ns.substring(from: at)
        let replacement = "[^\(label)]" + tail + "\n\n[^\(label)]: "
        return (replacement,
                NSRange(location: at, length: ns.length - at),
                NSRange(location: at + (replacement as NSString).length, length: 0))
    }

    /// The lowest positive integer, as a label, that `existing` does not hold.
    static func lowestFreeFootnoteLabel(existing: Set<String>) -> String {
        var n = 1
        while existing.contains(String(n)) { n += 1 }
        return String(n)
    }

    /// Every footnote label `text` uses: references `[^x]` and definitions
    /// `[^x]:`.
    static func footnoteLabels(in text: String) -> Set<String> {
        var labels = Set<String>()
        for (marker, _) in ManuscriptInlineScanner.scan(text) {
            if case .footnoteRef(let label) = marker { labels.insert(label) }
        }
        for (block, _) in ManuscriptBlocks.parse(text) {
            if case .footnoteDefinition(let label, _) = block { labels.insert(label) }
        }
        return labels
    }

    /// Insert Footnote at `location`, as one edit over the whole text. On a
    /// blank line the footnote belongs to the paragraph above; with none above,
    /// it starts the text there and keeps a blank line before what follows.
    static func footnoteEdit(in text: String, at location: Int) -> Edit {
        let ns = text as NSString
        let at = max(0, min(location, ns.length))
        var paragraph = paragraphRange(containing: at, in: ns)
        var caret = at
        var suffix = ""
        if paragraph.length == 0 {
            if let above = paragraphAbove(paragraph.location, in: ns) {
                paragraph = above
                caret = NSMaxRange(above)
            } else if paragraph.location < ns.length,
                      !isBlankLine(startingAt: NSMaxRange(ns.lineRange(
                        for: NSRange(location: paragraph.location, length: 0))), in: ns) {
                suffix = "\n"
            }
        }
        let note = footnote(in: ns.substring(with: paragraph),
                            caret: caret - paragraph.location,
                            existingLabels: footnoteLabels(in: text))
        return Edit(
            replacedRange: NSRange(location: paragraph.location + note.replacedRange.location,
                                   length: note.replacedRange.length),
            replacement: note.replacement + suffix,
            selection: NSRange(location: paragraph.location + note.caret.location, length: 0))
    }

    // MARK: - Paragraphs

    /// The blank-line paragraph containing `location`, without its trailing
    /// line break. On a blank line: an empty range at that line's start.
    static func paragraphRange(containing location: Int, in ns: NSString) -> NSRange {
        let at = max(0, min(location, ns.length))
        let line = ns.lineRange(for: NSRange(location: at, length: 0))
        if isBlank(line, in: ns) { return NSRange(location: line.location, length: 0) }
        var start = line.location
        while start > 0 {
            let above = ns.lineRange(for: NSRange(location: start - 1, length: 0))
            if isBlank(above, in: ns) { break }
            start = above.location
        }
        var last = line
        while NSMaxRange(last) < ns.length {
            let below = ns.lineRange(for: NSRange(location: NSMaxRange(last), length: 0))
            if isBlank(below, in: ns) { break }
            last = below
        }
        return NSRange(location: start, length: contentEnd(ofLine: last, in: ns) - start)
    }

    /// The nearest paragraph that ends above the blank line at `location`.
    private static func paragraphAbove(_ location: Int, in ns: NSString) -> NSRange? {
        var start = location
        while start > 0 {
            let above = ns.lineRange(for: NSRange(location: start - 1, length: 0))
            if !isBlank(above, in: ns) {
                return paragraphRange(containing: above.location, in: ns)
            }
            start = above.location
        }
        return nil
    }

    // MARK: - Lines

    private static func label(of block: ManuscriptBlock) -> ManuscriptLabel? {
        switch block {
        case .heading(_, _, let label): return label
        case .table(_, _, _, _, let label): return label
        case .figure(_, _, let label): return label
        case .footnoteDefinition, .other: return nil
        }
    }

    /// The end of `line`'s text, before its line break.
    private static func contentEnd(ofLine line: NSRange, in ns: NSString) -> Int {
        var end = NSMaxRange(line)
        while end > line.location, isLineBreak(ns.character(at: end - 1)) { end -= 1 }
        return end
    }

    private static func isBlank(_ line: NSRange, in ns: NSString) -> Bool {
        ns.substring(with: line).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Whether the line that ends (with its break) right before `location` is blank.
    private static func isBlankLine(endingBefore location: Int, in ns: NSString) -> Bool {
        guard location > 0 else { return true }
        return isBlank(ns.lineRange(for: NSRange(location: location - 1, length: 0)), in: ns)
    }

    /// Whether the line starting at `location` is blank, or there is none.
    private static func isBlankLine(startingAt location: Int, in ns: NSString) -> Bool {
        guard location < ns.length else { return true }
        return isBlank(ns.lineRange(for: NSRange(location: location, length: 0)), in: ns)
    }

    private static func isSpaceOrTab(_ c: unichar) -> Bool { c == 0x20 || c == 0x09 }
    private static func isLineBreak(_ c: unichar) -> Bool { c == 0x0A || c == 0x0D }
}
