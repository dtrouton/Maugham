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
                return
            }

            // Default classification — refined in Tasks 2-6.
            let element: ScreenplayElement = .action
            let content = trimmedTrailing
            lines.append(FountainLine(
                range: enclosingRange,
                element: element,
                content: content,
                isForced: false,
                sourceCase: Self.sourceCase(of: content)))
            prevBlank = false
            prevElement = element

            _ = prevElement   // silence "never read" until Tasks 2-6 use it
        }

        return FountainScript(lines: lines)
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
