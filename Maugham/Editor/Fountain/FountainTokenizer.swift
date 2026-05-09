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

        var lines: [FountainLine] = []
        var prevBlank = true
        var prevElement: ScreenplayElement = .action
        var blockState: BlockState = .normal

        nsText.enumerateSubstrings(in: fullRange, options: .byLines) {
            substring, _, enclosingRange, _ in
            guard let raw = substring else { return }
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

            // Inline note pass: locate any [[ ... ]] within the line, record
            // sub-ranges relative to the enclosing line range.
            let inlineSpans = Self.inlineNoteSpans(
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

        // Post-pass: orphan Character cue → Action (unchanged from Task 3).
        var corrected: [FountainLine] = []
        corrected.reserveCapacity(lines.count)
        for (index, line) in lines.enumerated() {
            if line.element == .character && !line.isForced {
                let next = (index + 1 < lines.count) ? lines[index + 1] : nil
                let nextIsBlank = next.map { $0.content.isEmpty } ?? true
                if nextIsBlank {
                    corrected.append(FountainLine(
                        range: line.range,
                        element: .action,
                        content: line.content,
                        isForced: false,
                        sourceCase: line.sourceCase,
                        inlineSpans: line.inlineSpans))
                    continue
                }
            }
            corrected.append(line)
        }
        return FountainScript(lines: corrected)
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

    private static func inlineNoteSpans(
        in trimmed: String,
        lineRange: NSRange,
        rawLine: String,
        nsText: NSString
    ) -> [FountainInlineSpan] {
        // We scan over the raw line (which retains leading whitespace and
        // any trailing whitespace before newline) so positions are correct
        // relative to lineRange.location.
        var result: [FountainInlineSpan] = []
        let raw = rawLine as NSString
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
}
