import Foundation

/// A fully parsed Fountain document. Pure value type with computed metrics.
public struct FountainScript: Equatable, Sendable {
    public let lines: [FountainLine]

    public init(lines: [FountainLine] = []) {
        self.lines = lines
    }

    public static let empty = FountainScript()

    /// Estimated page count using the Final Draft line-wrap heuristic.
    /// 60-char action lines, 35-char dialogue, 20-char parenthetical, 55 lines per page.
    /// Sections, synopses, boneyard, notes, and page breaks are excluded (working-doc metadata).
    /// Scene headings count as 2 lines (heading + implicit blank above).
    public var estimatedPageCount: Double {
        let linesPerPage = 55
        let charsPerActionLine = 60
        let charsPerDialogueLine = 35
        let charsPerParenthetical = 20
        let sceneHeadingExtraBlankLines = 1

        var totalLines = 0
        for line in lines {
            switch line.element {
            case .action:
                let len = line.content.count
                guard len > 0 else { break }
                let wraps = (len + charsPerActionLine - 1) / charsPerActionLine
                totalLines += max(wraps, 1)
            case .dialogue:
                let len = line.content.count
                let wraps = (len + charsPerDialogueLine - 1) / charsPerDialogueLine
                totalLines += max(wraps, 1)
            case .parenthetical:
                let len = line.content.count
                let wraps = (len + charsPerParenthetical - 1) / charsPerParenthetical
                totalLines += max(wraps, 1)
            case .sceneHeading:
                totalLines += 1 + sceneHeadingExtraBlankLines
            case .character, .transition, .centered, .lyric:
                totalLines += 1
            case .section, .synopsis, .boneyard, .note, .pageBreak:
                totalLines += 0
            }
        }
        return Double(totalLines) / Double(linesPerPage)
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
}
