import Foundation

/// A fully parsed Fountain document. Pure value type with computed metrics.
public struct FountainScript: Equatable, Sendable {
    public let lines: [FountainLine]
    public let titlePage: [TitlePageField]?

    public init(lines: [FountainLine] = [], titlePage: [TitlePageField]? = nil) {
        self.lines = lines
        self.titlePage = titlePage
    }

    public static let empty = FountainScript()

    /// Estimated page count using the Final Draft line-wrap heuristic.
    /// 60-char action lines, 35-char dialogue, 20-char parenthetical, 55 lines per page.
    /// Sections, synopses, boneyard, notes, and page breaks are excluded (working-doc metadata).
    /// Scene headings count as 2 lines (heading + implicit blank above).
    public var estimatedPageCount: Double {
        let linesPerPage = 55
        var totalLines = 0
        for line in lines {
            totalLines += Self.lineCount(for: line)
        }
        return Double(totalLines) / Double(linesPerPage)
    }

    /// 1-indexed page number where the given line begins. Walks lines from
    /// start, accumulating per-line line counts via the same heuristic as
    /// estimatedPageCount.
    public func pageNumber(at line: FountainLine) -> Int {
        let linesPerPage = 55
        var totalLines = 0
        for candidate in lines {
            if candidate.range.location == line.range.location {
                return (totalLines / linesPerPage) + 1
            }
            totalLines += Self.lineCount(for: candidate)
        }
        return 1
    }

    /// Line count for a single FountainLine — the wrapping/spacing heuristic
    /// shared by estimatedPageCount and pageNumber(at:).
    private static func lineCount(for line: FountainLine) -> Int {
        let charsPerActionLine = 60
        let charsPerDialogueLine = 35
        let charsPerParenthetical = 20
        let sceneHeadingExtraBlankLines = 1

        switch line.element {
        case .action:
            let len = line.content.count
            guard len > 0 else { return 0 }
            let wraps = (len + charsPerActionLine - 1) / charsPerActionLine
            return max(wraps, 1)
        case .dialogue:
            let len = line.content.count
            let wraps = (len + charsPerDialogueLine - 1) / charsPerDialogueLine
            return max(wraps, 1)
        case .parenthetical:
            let len = line.content.count
            let wraps = (len + charsPerParenthetical - 1) / charsPerParenthetical
            return max(wraps, 1)
        case .sceneHeading:
            return 1 + sceneHeadingExtraBlankLines
        case .character, .transition, .centered, .lyric:
            return 1
        case .section, .synopsis, .boneyard, .note, .pageBreak, .titlePage:
            return 0
        }
    }

    /// Distinct uppercased character names mentioned in the script. Populated
    /// from `.character` lines; used by 3b autocomplete.
    public var characterNames: Set<String> {
        Set(lines.compactMap { line in
            guard line.element == .character,
                  !line.content.isEmpty else { return nil }
            return line.content.uppercased()
        })
    }

    /// Estimated length of the scene starting at `line` in pages (fractional).
    /// Walks from `line` until the next sceneHeading (or end of script),
    /// summing line counts and dividing by linesPerPage.
    public func sceneLength(startingAt line: FountainLine) -> Double {
        let linesPerPage = 55
        var total = 0
        var insideTarget = false
        for candidate in lines {
            if candidate.range.location == line.range.location {
                insideTarget = true
                total += Self.lineCount(for: candidate)
                continue
            }
            if insideTarget {
                if candidate.element == .sceneHeading {
                    break
                }
                total += Self.lineCount(for: candidate)
            }
        }
        return Double(total) / Double(linesPerPage)
    }
}
