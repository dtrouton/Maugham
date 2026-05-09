import Foundation

/// A fully parsed Fountain document. Pure value type with computed metrics.
public struct FountainScript: Equatable, Sendable {
    public let lines: [FountainLine]

    public init(lines: [FountainLine] = []) {
        self.lines = lines
    }

    public static let empty = FountainScript()

    /// Estimated page count using the Final Draft line-wrap heuristic.
    /// Implementation lands in Task 7; defaults to 0 here so the type compiles.
    public var estimatedPageCount: Double { 0 }

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
