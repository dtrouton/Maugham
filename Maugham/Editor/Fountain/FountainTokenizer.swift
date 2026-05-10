import Foundation

/// Parses Fountain source text into a typed `FountainScript`. Pure logic;
/// no AppKit dependencies. Uses a line-based state machine because Fountain
/// element classification is fundamentally context-sensitive.
public struct FountainTokenizer: Sendable {
    public init() {}

    private enum BlockState {
        case normal
        case boneyard
        case noteBlock
    }

    public func parse(_ text: String) -> FountainScript {
        guard !text.isEmpty else { return .empty }
        let nsText = text as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)

        // Pre-pass: detect and parse title page block at document head.
        let (titlePage, titlePageEndOffset) = Self.parseTitlePage(
            nsText: nsText, fullRange: fullRange)

        var lines: [FountainLine] = []
        var prevBlank = true
        var prevElement: ScreenplayElement = .action
        var blockState: BlockState = .normal

        nsText.enumerateSubstrings(in: fullRange, options: .byLines) {
            substring, _, enclosingRange, _ in
            guard let raw = substring else { return }

            // If this line is inside the title page block, classify as .titlePage.
            // Don't update prevBlank/prevElement so body classification starts
            // from the same initial state regardless of title page close mode.
            if enclosingRange.location < titlePageEndOffset {
                let trimmed = raw.trimmingCharacters(in: .whitespaces)
                lines.append(FountainLine(
                    range: enclosingRange,
                    element: .titlePage,
                    content: trimmed,
                    isForced: false,
                    sourceCase: Self.sourceCase(of: trimmed),
                    inlineSpans: []))
                return
            }

            let trimmed = raw.trimmingCharacters(in: .whitespaces)

            // While inside a multi-line block, classify the line as that
            // block kind. Exit on the closing marker.
            switch blockState {
            case .boneyard:
                lines.append(FountainLine(
                    range: enclosingRange,
                    element: .boneyard,
                    content: trimmed,
                    isForced: false,
                    sourceCase: Self.sourceCase(of: trimmed)))
                if trimmed.contains("*/") { blockState = .normal }
                prevBlank = false
                prevElement = .boneyard
                return
            case .noteBlock:
                lines.append(FountainLine(
                    range: enclosingRange,
                    element: .note,
                    content: trimmed,
                    isForced: false,
                    sourceCase: Self.sourceCase(of: trimmed)))
                if trimmed.contains("]]") { blockState = .normal }
                prevBlank = false
                prevElement = .note
                return
            case .normal:
                break
            }

            if trimmed.isEmpty {
                lines.append(FountainLine(
                    range: enclosingRange,
                    element: .action,
                    content: "",
                    isForced: false,
                    sourceCase: .neutral))
                prevBlank = true
                prevElement = .action
                return
            }

            // Boneyard open on this line — single-line if "*/" appears,
            // otherwise enter .boneyard state.
            if trimmed.hasPrefix("/*") {
                let closesOnLine = trimmed.dropFirst(2).contains("*/")
                if !closesOnLine { blockState = .boneyard }
                lines.append(FountainLine(
                    range: enclosingRange,
                    element: .boneyard,
                    content: trimmed,
                    isForced: false,
                    sourceCase: Self.sourceCase(of: trimmed)))
                prevBlank = false
                prevElement = .boneyard
                return
            }

            // Block note open: line starts with [[ and either lacks ]] (multi-
            // line) or is entirely [[...]] (single-line block note).
            if trimmed.hasPrefix("[[") {
                let closesOnLine = trimmed.contains("]]")
                if !closesOnLine { blockState = .noteBlock }
                lines.append(FountainLine(
                    range: enclosingRange,
                    element: .note,
                    content: trimmed,
                    isForced: false,
                    sourceCase: Self.sourceCase(of: trimmed)))
                prevBlank = false
                prevElement = .note
                return
            }

            let classified = Self.classify(
                line: trimmed,
                prevBlank: prevBlank,
                prevElement: prevElement)

            // Inline span pass: locate notes, bold, italic, and underline spans
            // within the line, recorded relative to the enclosing line range.
            let inlineSpans = Self.inlineSpans(
                in: trimmed,
                lineRange: enclosingRange,
                rawLine: raw,
                nsText: nsText)

            lines.append(FountainLine(
                range: enclosingRange,
                element: classified.element,
                content: classified.content,
                isForced: classified.isForced,
                sourceCase: Self.sourceCase(of: classified.content),
                inlineSpans: inlineSpans))
            prevBlank = false
            prevElement = classified.element
        }

        // Trailing empty line: if the source text ends with "\n", emit a
        // zero-length FountainLine at the end so that a cursor at the very
        // end of the document lands on its own line rather than on the
        // previous line's range.
        if nsText.length > 0 && nsText.character(at: nsText.length - 1) == UInt16(("\n" as UnicodeScalar).value) {
            lines.append(FountainLine(
                range: NSRange(location: nsText.length, length: 0),
                element: .action,
                content: "",
                isForced: false,
                sourceCase: .neutral,
                inlineSpans: []))
        }

        return FountainScript(lines: lines, titlePage: titlePage)
    }

    // MARK: - Classification

    private struct Classified {
        let element: ScreenplayElement
        let content: String
        let isForced: Bool
    }

    private static func classify(
        line: String,
        prevBlank: Bool,
        prevElement: ScreenplayElement
    ) -> Classified {
        // Page break: three or more = with no other content.
        if Self.isPageBreak(line) {
            return Classified(
                element: .pageBreak,
                content: line,
                isForced: false)
        }

        // Sections: 1 to 6 leading '#' followed by space then content.
        if let section = Self.parseSection(line) {
            return Classified(
                element: .section(level: section.level),
                content: section.content,
                isForced: true)
        }

        // Synopsis: leading '=' followed by space then content (and not a
        // page break — already handled above).
        if line.hasPrefix("= ") {
            return Classified(
                element: .synopsis,
                content: String(line.dropFirst(2)),
                isForced: true)
        }

        // Forced scene heading: leading "." but not "..".
        if line.hasPrefix(".") && !line.hasPrefix("..") {
            let stripped = String(line.dropFirst())
            return Classified(
                element: .sceneHeading,
                content: stripped,
                isForced: true)
        }

        // Forced action bang.
        if line.hasPrefix("!") {
            return Classified(
                element: .action,
                content: String(line.dropFirst()),
                isForced: true)
        }

        // Centered: line wrapped in >...<. Recognize before forced-transition
        // (which is bare leading >) so >X< doesn't get classified as a
        // transition with content "X<".
        if line.hasPrefix(">") && line.hasSuffix("<") && line.count >= 2 {
            let inner = line.dropFirst().dropLast()
                .trimmingCharacters(in: .whitespaces)
            return Classified(
                element: .centered,
                content: inner,
                isForced: true)
        }

        // Forced transition: leading >.
        if line.hasPrefix(">") {
            let stripped = String(line.dropFirst())
                .trimmingCharacters(in: .whitespaces)
            return Classified(
                element: .transition,
                content: stripped,
                isForced: true)
        }

        // Lyric: leading ~.
        if line.hasPrefix("~") {
            return Classified(
                element: .lyric,
                content: String(line.dropFirst()),
                isForced: true)
        }

        // Forced character.
        if line.hasPrefix("@") {
            return Classified(
                element: .character,
                content: String(line.dropFirst()),
                isForced: true)
        }

        // Context-sensitive scene heading: starts with INT./EXT./EST./I/E./
        // INT/EXT., case-insensitive, and has a blank line above.
        if prevBlank && Self.isSceneHeadingPrefix(line) {
            return Classified(
                element: .sceneHeading,
                content: line,
                isForced: false)
        }

        // Context-sensitive transition: ALL-CAPS line ending in "TO:" with
        // a blank line above.
        if prevBlank && Self.isContextualTransition(line) {
            return Classified(
                element: .transition,
                content: line,
                isForced: false)
        }

        // Tentative Character: ALL-CAPS letters with blank line above.
        // The "followed by a non-blank line" requirement is enforced in a
        // post-pass (second loop), since enumerateSubstrings doesn't give
        // us forward lookahead cheaply.
        if prevBlank && Self.isAllCapsCueCandidate(line) {
            return Classified(
                element: .character,
                content: line,
                isForced: false)
        }

        // Inside a dialogue block: parenthetical or continued dialogue.
        if prevElement == .character || prevElement == .parenthetical || prevElement == .dialogue {
            if line.hasPrefix("(") && line.hasSuffix(")") {
                return Classified(
                    element: .parenthetical,
                    content: line,
                    isForced: false)
            }
            return Classified(
                element: .dialogue,
                content: line,
                isForced: false)
        }

        return Classified(
            element: .action,
            content: line,
            isForced: false)
    }

    private static func isAllCapsCueCandidate(_ line: String) -> Bool {
        var hasLetter = false
        for ch in line {
            if ch.isLetter {
                hasLetter = true
                if ch.isLowercase { return false }
            }
        }
        return hasLetter
    }

    private static func isContextualTransition(_ line: String) -> Bool {
        guard line.uppercased().hasSuffix("TO:") else { return false }
        return Self.isAllCapsCueCandidate(line)
    }

    private static let sceneHeadingPrefixes = [
        "INT.", "EXT.", "EST.", "I/E.", "INT/EXT."
    ]

    private static func isSceneHeadingPrefix(_ line: String) -> Bool {
        let upper = line.uppercased()
        for prefix in sceneHeadingPrefixes {
            if upper.hasPrefix(prefix + " ") || upper == prefix {
                return true
            }
        }
        return false
    }

    private static func isPageBreak(_ line: String) -> Bool {
        guard line.count >= 3 else { return false }
        return line.allSatisfy { $0 == "=" }
    }

    private static func parseSection(_ line: String) -> (level: Int, content: String)? {
        var level = 0
        for ch in line {
            if ch == "#" { level += 1 } else { break }
            if level > 6 { return nil }   // 7+ # is action
        }
        guard level >= 1, level <= 6 else { return nil }
        let after = line.dropFirst(level)
        guard after.first == " " else { return nil }
        let content = String(after.dropFirst())
        return (level, content)
    }

    static func sourceCase(of text: String) -> SourceCase {
        var hasUpper = false
        var hasLower = false
        var hasLetter = false
        for ch in text {
            if ch.isLetter {
                hasLetter = true
                if ch.isUppercase { hasUpper = true }
                if ch.isLowercase { hasLower = true }
            }
        }
        if !hasLetter { return .neutral }
        if hasUpper && hasLower { return .mixed }
        if hasUpper { return .upper }
        return .lower
    }

    /// Returns inline spans (notes, italic, bold, underline) detected within
    /// a single line. Order: notes first, then bold (longest first), then
    /// italic (skipping ranges already inside bold), then underline.
    private static func inlineSpans(
        in trimmed: String,
        lineRange: NSRange,
        rawLine: String,
        nsText: NSString
    ) -> [FountainInlineSpan] {
        var result: [FountainInlineSpan] = []
        let raw = rawLine as NSString

        // 1. Inline notes (existing behavior).
        result.append(contentsOf: scanNotes(in: raw, lineRange: lineRange))

        // 2. Bold **text**.
        result.append(contentsOf: scanRegex(
            pattern: #"\*\*([^*\n]+)\*\*"#,
            in: raw, lineRange: lineRange, kind: .bold))

        // 3. Italic *text* — delimiters must not be part of **. Lone * on each
        //    side; content may contain ** (bold inside italic).
        result.append(contentsOf: scanRegex(
            pattern: #"(?<!\*)\*(?!\*)(.+?)(?<!\*)\*(?!\*)"#,
            in: raw, lineRange: lineRange, kind: .italic))

        // 4. Underline _text_.
        result.append(contentsOf: scanRegex(
            pattern: #"_([^_\n]+)_"#,
            in: raw, lineRange: lineRange, kind: .underline))

        return result
    }

    private static func scanNotes(
        in raw: NSString, lineRange: NSRange
    ) -> [FountainInlineSpan] {
        // We scan over the raw line (which retains leading whitespace and
        // any trailing whitespace before newline) so positions are correct
        // relative to lineRange.location.
        var result: [FountainInlineSpan] = []
        let rawLength = raw.length
        var search = NSRange(location: 0, length: rawLength)

        while search.length > 0 {
            let openRange = raw.range(of: "[[", options: [], range: search)
            guard openRange.location != NSNotFound else { break }
            let afterOpen = NSRange(
                location: openRange.location + 2,
                length: rawLength - (openRange.location + 2))
            let closeRange = raw.range(of: "]]", options: [], range: afterOpen)
            guard closeRange.location != NSNotFound else { break }
            let spanStart = lineRange.location + openRange.location
            let spanLength = (closeRange.location + 2) - openRange.location
            result.append(FountainInlineSpan(
                range: NSRange(location: spanStart, length: spanLength),
                kind: .note))
            let nextStart = closeRange.location + 2
            search = NSRange(
                location: nextStart,
                length: rawLength - nextStart)
        }
        return result
    }

    private static func scanRegex(
        pattern: String,
        in raw: NSString,
        lineRange: NSRange,
        kind: FountainInlineSpan.Kind
    ) -> [FountainInlineSpan] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return []
        }
        var result: [FountainInlineSpan] = []
        let fullRange = NSRange(location: 0, length: raw.length)
        regex.enumerateMatches(in: raw as String, options: [],
                               range: fullRange) { match, _, _ in
            guard let match else { return }
            let outer = match.range
            let spanStart = lineRange.location + outer.location
            result.append(FountainInlineSpan(
                range: NSRange(location: spanStart, length: outer.length),
                kind: kind))
        }
        return result
    }

    // MARK: - Title Page Pre-pass

    private static let titlePageKeyMap: [String: String] = [
        "title": "Title",
        "credit": "Credit",
        "author": "Author",
        "authors": "Author",
        "source": "Source",
        "notes": "Notes",
        "draft date": "Draft date",
        "contact": "Contact",
        "copyright": "Copyright",
    ]

    private static func canonicalTitlePageKey(_ raw: String) -> String? {
        let lower = raw.lowercased()
        return titlePageKeyMap[lower]
    }

    /// Parse the title page block at the document head, if present.
    /// Returns (fields, endByteOffset). endByteOffset is the offset where
    /// the body begins (after the title page block + closing blank line).
    /// If no title page is present, returns (nil, 0).
    private static func parseTitlePage(
        nsText: NSString,
        fullRange: NSRange
    ) -> (fields: [TitlePageField]?, endOffset: Int) {
        // Find the first non-empty line; check if it matches Key: Value with
        // a recognized key. If not, no title page.
        var firstNonEmpty: NSRange?
        nsText.enumerateSubstrings(in: fullRange, options: .byLines) {
            sub, _, enclosing, stop in
            guard let s = sub else { return }
            let trimmed = s.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty {
                firstNonEmpty = enclosing
                stop.pointee = true
            }
        }
        guard let firstLineRange = firstNonEmpty else {
            return (nil, 0)
        }
        let firstLineText = nsText.substring(with: firstLineRange)
            .trimmingCharacters(in: .whitespaces)
        guard let firstKey = parseKey(firstLineText),
              canonicalTitlePageKey(firstKey) != nil else {
            // First line doesn't match recognized title page key.
            return (nil, 0)
        }

        // Walk lines from the start, accumulating title page fields until
        // the close condition.
        var fields: [TitlePageField] = []
        var currentKey: String?
        var currentValue: [String] = []
        var currentRange: NSRange = NSRange(location: 0, length: 0)
        var endOffset = 0

        nsText.enumerateSubstrings(in: fullRange, options: .byLines) {
            sub, _, enclosing, stop in
            guard let s = sub else { return }
            let trimmed = s.trimmingCharacters(in: .whitespaces)
            let leadingWhitespaceCount = s.prefix { $0 == " " || $0 == "\t" }.count
            let isIndentedContinuation = leadingWhitespaceCount >= 3
                || (s.hasPrefix("\t"))

            // Close on blank line.
            if trimmed.isEmpty {
                Self.flushField(currentKey: &currentKey,
                                currentValue: &currentValue,
                                currentRange: &currentRange,
                                fields: &fields)
                endOffset = NSMaxRange(enclosing)
                stop.pointee = true
                return
            }

            // Try to match Key: Value (top-level key).
            if let parsedKey = parseKey(trimmed),
               !isIndentedContinuation {
                // New field. Flush current.
                Self.flushField(currentKey: &currentKey,
                                currentValue: &currentValue,
                                currentRange: &currentRange,
                                fields: &fields)
                let canonical = canonicalTitlePageKey(parsedKey) ?? parsedKey
                currentKey = canonical
                let valueStart = (trimmed as NSString).range(of: ":").location + 1
                let valueText = (trimmed as NSString).substring(from: valueStart)
                    .trimmingCharacters(in: .whitespaces)
                currentValue = valueText.isEmpty ? [] : [valueText]
                currentRange = enclosing
            } else if currentKey != nil && isIndentedContinuation {
                // Continuation of previous field.
                currentValue.append(trimmed)
                currentRange = NSRange(
                    location: currentRange.location,
                    length: NSMaxRange(enclosing) - currentRange.location)
            } else {
                // Non-key non-indented line — closes the title page.
                Self.flushField(currentKey: &currentKey,
                                currentValue: &currentValue,
                                currentRange: &currentRange,
                                fields: &fields)
                endOffset = enclosing.location
                stop.pointee = true
                return
            }
        }

        // If we reached end of document without an explicit close, flush.
        Self.flushField(currentKey: &currentKey,
                        currentValue: &currentValue,
                        currentRange: &currentRange,
                        fields: &fields)
        if endOffset == 0 {
            endOffset = fullRange.length
        }

        return (fields.isEmpty ? nil : fields, endOffset)
    }

    private static func flushField(
        currentKey: inout String?,
        currentValue: inout [String],
        currentRange: inout NSRange,
        fields: inout [TitlePageField]
    ) {
        guard let key = currentKey else { return }
        let value = currentValue.joined(separator: "\n")
        fields.append(TitlePageField(
            key: key, value: value, range: currentRange))
        currentKey = nil
        currentValue = []
        currentRange = NSRange(location: 0, length: 0)
    }

    /// Parse "Key: ..." into the key (without trimming surrounding whitespace).
    /// Returns nil if the line doesn't have a colon or has invalid key format.
    private static func parseKey(_ line: String) -> String? {
        guard let colonIndex = line.firstIndex(of: ":") else { return nil }
        let key = String(line[..<colonIndex])
            .trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty,
              !key.contains("\n") else { return nil }
        return key
    }
}
