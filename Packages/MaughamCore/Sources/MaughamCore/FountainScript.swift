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
    /// Dual-dialogue pairs count as the height of the LONGER block, not the sum,
    /// because side-by-side rendering in print shares a vertical band.
    public var estimatedPageCount: Double {
        let linesPerPage = 55
        let rawTotal = lines.reduce(0) { $0 + Self.lineCount(for: $1) }
        let adjustment = Self.dualPairAdjustment(lines: lines)
        return Double(max(0, rawTotal - adjustment)) / Double(linesPerPage)
    }

    /// 1-indexed page number where the given line begins. Walks lines from
    /// start, accumulating per-line line counts via the same heuristic as
    /// estimatedPageCount, and subtracting dual-pair adjustments for any
    /// pair whose second block closed strictly BEFORE the target line.
    public func pageNumber(at line: FountainLine) -> Int {
        let linesPerPage = 55
        var totalLines = 0
        var adjustmentAccrued = 0
        // Track pair-pending state in a single pass.
        var previousBlockLines: Int? = nil
        var currentBlockLines: Int? = nil
        var currentBlockIsDualSecond = false

        for candidate in lines {
            if candidate.range.location == line.range.location {
                // Finalize any in-flight pair before computing return value.
                if let prev = previousBlockLines, let cur = currentBlockLines,
                   currentBlockIsDualSecond {
                    adjustmentAccrued += min(prev, cur)
                }
                let adjusted = max(0, totalLines - adjustmentAccrued)
                return (adjusted / linesPerPage) + 1
            }

            let candidateCount = Self.lineCount(for: candidate)
            totalLines += candidateCount

            switch candidate.element {
            case .character:
                // Closing prior block(s).
                if let prev = previousBlockLines, let cur = currentBlockLines,
                   currentBlockIsDualSecond {
                    adjustmentAccrued += min(prev, cur)
                    previousBlockLines = nil
                    currentBlockLines = nil
                    currentBlockIsDualSecond = false
                }
                // Promote in-flight block, then start fresh.
                if currentBlockLines != nil {
                    previousBlockLines = currentBlockLines
                }
                currentBlockLines = candidateCount
                currentBlockIsDualSecond = candidate.isDualSecond
            case .dialogue, .parenthetical:
                currentBlockLines = (currentBlockLines ?? 0) + candidateCount
            default:
                // Block boundary. Settle any pair.
                if let prev = previousBlockLines, let cur = currentBlockLines,
                   currentBlockIsDualSecond {
                    adjustmentAccrued += min(prev, cur)
                }
                // After any non-dialogue/non-character line, drop the
                // pending blocks — a non-dialogue line cannot be the
                // first half of a dual pair.
                previousBlockLines = nil
                currentBlockLines = nil
                currentBlockIsDualSecond = false
            }
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

    /// Groups consecutive character + dialogue/parenthetical lines into blocks,
    /// preserving each block's isDualSecond flag (derived from its character cue).
    private static func dialogueBlocks(
        in lines: [FountainLine]
    ) -> [(linesInBlock: [FountainLine], isDualSecond: Bool)] {
        var blocks: [(linesInBlock: [FountainLine], isDualSecond: Bool)] = []
        var current: [FountainLine] = []
        var currentIsDualSecond = false

        func flush() {
            if !current.isEmpty {
                blocks.append((current, currentIsDualSecond))
            }
            current = []
            currentIsDualSecond = false
        }

        for line in lines {
            switch line.element {
            case .character:
                flush()
                current.append(line)
                currentIsDualSecond = line.isDualSecond
            case .dialogue, .parenthetical:
                if !current.isEmpty {
                    current.append(line)
                }
            default:
                flush()
            }
        }
        flush()
        return blocks
    }

    /// Sum of lines saved by treating each (firstBlock, dualSecondBlock) pair
    /// as max(first, second) instead of first+second. Walks blocks in order;
    /// when block i+1 is isDualSecond, blocks i and i+1 form a pair.
    /// Greedy two-at-a-time pairing — for a chain (A, B^, C^), pairs (A,B),
    /// leaves C solo. Documented limitation; chain-of-three is exotic.
    private static func dualPairAdjustment(lines: [FountainLine]) -> Int {
        let blocks = dialogueBlocks(in: lines)
        var adjustment = 0
        var i = 0
        while i < blocks.count - 1 {
            if blocks[i + 1].isDualSecond {
                let firstLines = blocks[i].linesInBlock.reduce(0) {
                    $0 + lineCount(for: $1)
                }
                let secondLines = blocks[i + 1].linesInBlock.reduce(0) {
                    $0 + lineCount(for: $1)
                }
                adjustment += min(firstLines, secondLines)
                i += 2
            } else {
                i += 1
            }
        }
        return adjustment
    }

    /// One scene's heading line plus its derived navigator metrics.
    public struct SceneSummary: Equatable, Sendable {
        /// The `.sceneHeading` line that starts this scene.
        public let line: FountainLine
        /// 1-indexed page number where this scene begins. Equals
        /// `pageNumber(at: line)`.
        public let pageNumber: Int
        /// Estimated length of this scene in pages (fractional). Equals
        /// `sceneLength(startingAt: line)`.
        public let length: Double

        public init(line: FountainLine, pageNumber: Int, length: Double) {
            self.line = line
            self.pageNumber = pageNumber
            self.length = length
        }
    }

    /// All scene headings with their page number and length, computed in a
    /// SINGLE O(lines) pass. This is the cached/one-pass replacement for
    /// calling `pageNumber(at:)` + `sceneLength(startingAt:)` per scene per
    /// render (each of which is an O(document) walk — tripwire 4). The page-
    /// number arithmetic reuses the exact state machine of `pageNumber(at:)`,
    /// and each scene's length reuses `lineCount(for:)` + `dualPairAdjustment`
    /// over the scene's slice — same formulas, no duplication. Verified line-
    /// for-line against the per-call APIs by `SceneSummariesParityTests`.
    public func sceneSummaries() -> [SceneSummary] {
        let linesPerPage = 55

        // --- pageNumber(at:) running state, replayed once over all lines. ---
        var totalLines = 0
        var adjustmentAccrued = 0
        var previousBlockLines: Int? = nil
        var currentBlockLines: Int? = nil
        var currentBlockIsDualSecond = false

        // --- per-scene length accumulation ---
        var summaries: [SceneSummary] = []
        var pendingHeading: FountainLine? = nil
        var pendingHeadingPage = 1
        var pendingSceneLines: [FountainLine] = []

        func finalizePendingScene() {
            guard let heading = pendingHeading else { return }
            let rawTotal = pendingSceneLines.reduce(0) { $0 + Self.lineCount(for: $1) }
            let adjustment = Self.dualPairAdjustment(lines: pendingSceneLines)
            let length = Double(max(0, rawTotal - adjustment)) / Double(linesPerPage)
            summaries.append(
                SceneSummary(line: heading, pageNumber: pendingHeadingPage, length: length))
        }

        for candidate in lines {
            if candidate.element == .sceneHeading {
                // Snapshot the page number for THIS heading using the same
                // "finalize any in-flight pair for the return value only"
                // rule pageNumber(at:) uses — without mutating the persistent
                // running state (pageNumber(at:) returns before mutating it).
                var pairBonus = 0
                if let prev = previousBlockLines, let cur = currentBlockLines,
                   currentBlockIsDualSecond {
                    pairBonus = min(prev, cur)
                }
                let adjusted = max(0, totalLines - (adjustmentAccrued + pairBonus))
                let page = (adjusted / linesPerPage) + 1

                // The previous scene ends just before this heading.
                finalizePendingScene()
                pendingHeading = candidate
                pendingHeadingPage = page
                pendingSceneLines = [candidate]
            } else if pendingHeading != nil {
                pendingSceneLines.append(candidate)
            }

            // Advance the pageNumber(at:) state machine past this line.
            let candidateCount = Self.lineCount(for: candidate)
            totalLines += candidateCount
            switch candidate.element {
            case .character:
                if let prev = previousBlockLines, let cur = currentBlockLines,
                   currentBlockIsDualSecond {
                    adjustmentAccrued += min(prev, cur)
                    previousBlockLines = nil
                    currentBlockLines = nil
                    currentBlockIsDualSecond = false
                }
                if currentBlockLines != nil {
                    previousBlockLines = currentBlockLines
                }
                currentBlockLines = candidateCount
                currentBlockIsDualSecond = candidate.isDualSecond
            case .dialogue, .parenthetical:
                currentBlockLines = (currentBlockLines ?? 0) + candidateCount
            default:
                if let prev = previousBlockLines, let cur = currentBlockLines,
                   currentBlockIsDualSecond {
                    adjustmentAccrued += min(prev, cur)
                }
                previousBlockLines = nil
                currentBlockLines = nil
                currentBlockIsDualSecond = false
            }
        }
        finalizePendingScene()
        return summaries
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
    /// summing line counts and applying dual-pair adjustment within the scene.
    public func sceneLength(startingAt line: FountainLine) -> Double {
        let linesPerPage = 55
        var sceneLines: [FountainLine] = []
        var insideTarget = false
        for candidate in lines {
            if candidate.range.location == line.range.location {
                insideTarget = true
                sceneLines.append(candidate)
                continue
            }
            if insideTarget {
                if candidate.element == .sceneHeading {
                    break
                }
                sceneLines.append(candidate)
            }
        }
        let rawTotal = sceneLines.reduce(0) { $0 + Self.lineCount(for: $1) }
        let adjustment = Self.dualPairAdjustment(lines: sceneLines)
        return Double(max(0, rawTotal - adjustment)) / Double(linesPerPage)
    }
}
