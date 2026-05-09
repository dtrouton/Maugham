import Foundation

/// Parses Fountain source text into a typed `FountainScript`. Pure logic;
/// no AppKit dependencies. Uses a line-based state machine because Fountain
/// element classification is fundamentally context-sensitive.
public struct FountainTokenizer: Sendable {
    public init() {}

    public func parse(_ text: String) -> FountainScript {
        guard !text.isEmpty else { return .empty }
        let nsText = text as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)

        var lines: [FountainLine] = []
        var prevBlank = true
        var prevElement: ScreenplayElement = .action

        nsText.enumerateSubstrings(in: fullRange, options: .byLines) {
            substring, _, enclosingRange, _ in
            guard let raw = substring else { return }
            let trimmedTrailing = raw.trimmingCharacters(in: .whitespaces)

            if trimmedTrailing.isEmpty {
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

            let classified = Self.classify(
                line: trimmedTrailing,
                prevBlank: prevBlank,
                prevElement: prevElement)

            lines.append(FountainLine(
                range: enclosingRange,
                element: classified.element,
                content: classified.content,
                isForced: classified.isForced,
                sourceCase: Self.sourceCase(of: classified.content)))
            prevBlank = false
            prevElement = classified.element
        }

        // Post-pass: a tentative Character cue must be followed by a non-blank
        // line. If it isn't, demote it to .action.
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
}
