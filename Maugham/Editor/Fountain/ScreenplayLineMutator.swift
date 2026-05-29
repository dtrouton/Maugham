import Foundation
import MaughamCore

/// Local context for a screenplay line — used by ScreenplayLineMutator to
/// decide whether a forced-syntax marker is needed for elements that have
/// context-sensitive alternatives (Character, Scene Heading, Transition).
public struct LineNeighborhood: Equatable, Sendable {
    public let prevIsBlank: Bool
    public let nextIsBlank: Bool

    public init(prevIsBlank: Bool, nextIsBlank: Bool) {
        self.prevIsBlank = prevIsBlank
        self.nextIsBlank = nextIsBlank
    }
}

/// Pure logic that rewrites a single line's source text to make it classify
/// as a target screenplay element. For elements with context-sensitive
/// alternatives (Character, Scene Heading, Transition), the mutator leaves
/// the text alone when the neighborhood already satisfies the alternative.
/// For elements without alternatives (Parenthetical, Lyric, Section,
/// Synopsis), the marker is always applied.
public enum ScreenplayLineMutator {

    public struct Result: Equatable {
        public let text: String
        /// Cursor offset within `text`, in UTF-16 units, where the caller
        /// should place the insertion point after replacement.
        public let cursorOffset: Int
    }

    public static func mutate(
        line: String,
        to target: ScreenplayElement,
        neighborhood: LineNeighborhood
    ) -> Result {
        switch target {
        case .action:           return mutateToAction(line: line)
        case .sceneHeading:     return mutateToSceneHeading(line: line, neighborhood: neighborhood)
        case .character:        return mutateToCharacter(line: line, neighborhood: neighborhood)
        case .dialogue:         return Result(text: line, cursorOffset: line.utf16.count)
        case .parenthetical:    return mutateToParenthetical(line: line)
        case .transition:       return mutateToTransition(line: line, neighborhood: neighborhood)
        case .centered:
            let new = ">\(line)<"
            return Result(text: new, cursorOffset: (new as NSString).length)
        case .lyric:            return mutateToLyric(line: line)
        case .section:
            let stripped = stripActionMarkers(line)
            let new = "# \(stripped)"
            return Result(text: new, cursorOffset: (new as NSString).length)
        case .synopsis:
            let stripped = stripActionMarkers(line)
            let new = "= \(stripped)"
            return Result(text: new, cursorOffset: (new as NSString).length)
        case .pageBreak, .boneyard, .note, .titlePage:
            // Not reachable from cycle. Leave text alone.
            return Result(text: line, cursorOffset: line.utf16.count)
        }
    }

    // MARK: - Per-element

    private static func mutateToAction(line: String) -> Result {
        let stripped = stripActionMarkers(line)
        return Result(text: stripped, cursorOffset: (stripped as NSString).length)
    }

    private static func mutateToSceneHeading(
        line: String,
        neighborhood: LineNeighborhood
    ) -> Result {
        let stripped = stripActionMarkers(line)
        if neighborhood.prevIsBlank && hasSceneHeadingPrefix(stripped) {
            return Result(text: stripped, cursorOffset: (stripped as NSString).length)
        }
        let new = "." + stripped
        return Result(text: new, cursorOffset: (new as NSString).length)
    }

    private static func mutateToCharacter(
        line: String,
        neighborhood: LineNeighborhood
    ) -> Result {
        let stripped = stripActionMarkers(line)
        if isAllUppercaseLetters(stripped)
            && neighborhood.prevIsBlank
            && !neighborhood.nextIsBlank {
            return Result(text: stripped, cursorOffset: (stripped as NSString).length)
        }
        let new = "@" + stripped
        return Result(text: new, cursorOffset: (new as NSString).length)
    }

    private static func mutateToParenthetical(line: String) -> Result {
        let stripped = stripActionMarkers(line)
        let new = "(\(stripped))"
        // Cursor inside the opening paren — between '(' and the content.
        return Result(text: new, cursorOffset: 1)
    }

    private static func mutateToTransition(
        line: String,
        neighborhood: LineNeighborhood
    ) -> Result {
        let stripped = stripActionMarkers(line)
        if neighborhood.prevIsBlank
            && isAllUppercaseLetters(stripped)
            && stripped.uppercased().hasSuffix("TO:") {
            return Result(text: stripped, cursorOffset: (stripped as NSString).length)
        }
        let new = "> " + stripped
        return Result(text: new, cursorOffset: (new as NSString).length)
    }

    private static func mutateToLyric(line: String) -> Result {
        let stripped = stripActionMarkers(line)
        let new = "~" + stripped
        return Result(text: new, cursorOffset: (new as NSString).length)
    }

    // MARK: - Helpers

    private static func stripActionMarkers(_ line: String) -> String {
        // Strip leading forced markers: @, !, ., >, ~. Strip wrapping parens.
        var result = line

        if result.hasPrefix("(") && result.hasSuffix(")") && result.count >= 2 {
            result = String(result.dropFirst().dropLast())
            return result
        }

        if let first = result.first {
            switch first {
            case "@", "!", "~":
                result = String(result.dropFirst())
            case ".":
                if !result.hasPrefix("..") {
                    result = String(result.dropFirst())
                }
            case ">":
                // > or "> " with a space.
                result = String(result.dropFirst())
                if result.hasPrefix(" ") {
                    result = String(result.dropFirst())
                }
            default:
                break
            }
        }

        // Strip leading 1-6 # followed by space (section).
        if let parsed = parseSectionMarker(result) {
            result = parsed
        }

        // Strip leading "= " (synopsis).
        if result.hasPrefix("= ") {
            result = String(result.dropFirst(2))
        }

        return result
    }

    private static func parseSectionMarker(_ line: String) -> String? {
        var hashes = 0
        for ch in line {
            if ch == "#" { hashes += 1 } else { break }
            if hashes > 6 { return nil }
        }
        guard hashes >= 1, hashes <= 6 else { return nil }
        let after = line.dropFirst(hashes)
        guard after.first == " " else { return nil }
        return String(after.dropFirst())
    }

    private static func isAllUppercaseLetters(_ line: String) -> Bool {
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
        "INT.", "EXT.", "EST.", "I/E.", "INT/EXT.",
    ]

    private static func hasSceneHeadingPrefix(_ line: String) -> Bool {
        let upper = line.uppercased()
        for prefix in sceneHeadingPrefixes {
            if upper.hasPrefix(prefix + " ") || upper == prefix {
                return true
            }
        }
        return false
    }
}
