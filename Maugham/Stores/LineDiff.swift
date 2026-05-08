import Foundation

/// Pure line-level diff between two strings, expressed as hunks of lines.
/// Used by the conflict diff sheet to render side-by-side mine/cloud
/// comparisons. Built on Foundation's `CollectionDifference`.
public struct LineDiff: Equatable, Sendable {

    public enum LineKind: Equatable, Sendable {
        case context
        case removed   // present only in mine
        case added     // present only in cloud
    }

    public struct DiffLine: Equatable, Sendable {
        public let kind: LineKind
        public let mineLineNumber: Int?
        public let cloudLineNumber: Int?
        public let text: String

        public init(kind: LineKind, mineLineNumber: Int?, cloudLineNumber: Int?, text: String) {
            self.kind = kind
            self.mineLineNumber = mineLineNumber
            self.cloudLineNumber = cloudLineNumber
            self.text = text
        }
    }

    public struct Hunk: Equatable, Sendable {
        public let lines: [DiffLine]

        public init(lines: [DiffLine]) {
            self.lines = lines
        }
    }

    public let hunks: [Hunk]
    public let totalMineLines: Int
    public let totalCloudLines: Int

    public init(mine: String, cloud: String, contextRadius: Int = 3) {
        let mineLines = LineDiff.split(mine)
        let cloudLines = LineDiff.split(cloud)
        self.totalMineLines = mineLines.count
        self.totalCloudLines = cloudLines.count

        let diff = cloudLines.difference(from: mineLines)

        var removedMineIndices = Set<Int>()
        var addedCloudIndices = Set<Int>()
        for change in diff {
            switch change {
            case .remove(let offset, _, _): removedMineIndices.insert(offset)
            case .insert(let offset, _, _): addedCloudIndices.insert(offset)
            }
        }

        var flat: [DiffLine] = []
        var mi = 0, ci = 0
        while mi < mineLines.count || ci < cloudLines.count {
            let mineRemoved = mi < mineLines.count && removedMineIndices.contains(mi)
            let cloudAdded = ci < cloudLines.count && addedCloudIndices.contains(ci)
            if mineRemoved {
                flat.append(DiffLine(
                    kind: .removed,
                    mineLineNumber: mi + 1,
                    cloudLineNumber: nil,
                    text: mineLines[mi]))
                mi += 1
            } else if cloudAdded {
                flat.append(DiffLine(
                    kind: .added,
                    mineLineNumber: nil,
                    cloudLineNumber: ci + 1,
                    text: cloudLines[ci]))
                ci += 1
            } else if mi < mineLines.count && ci < cloudLines.count {
                flat.append(DiffLine(
                    kind: .context,
                    mineLineNumber: mi + 1,
                    cloudLineNumber: ci + 1,
                    text: mineLines[mi]))
                mi += 1; ci += 1
            } else if mi < mineLines.count {
                flat.append(DiffLine(
                    kind: .removed,
                    mineLineNumber: mi + 1,
                    cloudLineNumber: nil,
                    text: mineLines[mi]))
                mi += 1
            } else if ci < cloudLines.count {
                flat.append(DiffLine(
                    kind: .added,
                    mineLineNumber: nil,
                    cloudLineNumber: ci + 1,
                    text: cloudLines[ci]))
                ci += 1
            }
        }

        self.hunks = LineDiff.buildHunks(from: flat, contextRadius: contextRadius)
    }

    private static func split(_ s: String) -> [String] {
        // Drop a trailing empty line that comes from a trailing \n so we don't
        // produce a phantom diff entry for it.
        var lines = s.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        return lines
    }

    private static func buildHunks(
        from flat: [DiffLine],
        contextRadius: Int
    ) -> [Hunk] {
        let changedIndices = flat.indices.filter { flat[$0].kind != .context }
        guard !changedIndices.isEmpty else { return [] }

        var windows: [(start: Int, end: Int)] = []
        for idx in changedIndices {
            let start = max(0, idx - contextRadius)
            let end = min(flat.count - 1, idx + contextRadius)
            if let last = windows.last, start <= last.end + 1 {
                windows[windows.count - 1] = (last.start, max(last.end, end))
            } else {
                windows.append((start, end))
            }
        }

        return windows.map { window in
            Hunk(lines: Array(flat[window.start...window.end]))
        }
    }
}
