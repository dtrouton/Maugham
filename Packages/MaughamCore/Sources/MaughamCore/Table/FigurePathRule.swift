import Foundation

/// **The lexical half of the figure-path rule** (report plan 7a Task 2): what
/// can be decided about a figure line's path from the STRING alone, no disk.
/// Publish's `FigureImageResolver` calls it before touching the disk, and the
/// editor's figure-line lookup (`FigureLineResolution`) and plan 7b's F9
/// diagnostic share it, so the editor and a build agree on what a path means
/// (never the weaker dead `ManuscriptIndex` rule).
///
/// A figure path is written relative to its piece's own file; it is accepted
/// only inside the project's `figures/`, the project's `research/`, or, for a
/// Collection piece at `pieces/<x>/<file>`, that piece's own
/// `pieces/<x>/research/`. Not percent-decoded: what is written is what is
/// looked up.
public enum FigurePathRule {

    public enum Outcome: Equatable, Sendable {
        /// The project-relative target components, and the allowed folder
        /// (`["figures"]`, `["research"]`, `["pieces", x, "research"]`) it
        /// sits strictly inside.
        case inside(target: [String], root: [String])
        /// Absolute, `~`, a URL scheme, a `..` out of the project, or a
        /// folder that isn't figures or research.
        case notLocal
    }

    /// - Parameters:
    ///   - path: as written in the manuscript, relative to the piece's file.
    ///   - piecePath: the piece's project-relative manuscript path.
    public static func lexical(_ path: String, piecePath: String) -> Outcome {
        guard isRelative(path), isRelative(piecePath),
              let piece = standardised(components(piecePath)), !piece.isEmpty,
              let target = standardised(Array(piece.dropLast()) + components(path)),
              let root = allowedRoot(of: target, piece: piece)
        else { return .notLocal }
        return .inside(target: target, root: root)
    }

    /// No absolute path, no home-relative path, no URL scheme.
    static func isRelative(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.hasPrefix("~") else { return false }
        // A scheme is letters/digits/+/./- then a colon, before any slash.
        let head = path.prefix { $0 != "/" }
        if let colon = head.firstIndex(of: ":") {
            let scheme = head[head.startIndex..<colon]
            if let first = scheme.first, first.isLetter,
               scheme.allSatisfy({ $0.isLetter || $0.isNumber || "+.-".contains($0) }) {
                return false
            }
        }
        return true
    }

    static func components(_ path: String) -> [String] {
        path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    }

    /// Folds `.` and `..`; nil when a `..` climbs above the project root —
    /// an escape is refused even if a later segment would climb back in.
    static func standardised(_ parts: [String]) -> [String]? {
        var out: [String] = []
        for part in parts {
            switch part {
            case ".": continue
            case "..":
                guard !out.isEmpty else { return nil }
                out.removeLast()
            default: out.append(part)
            }
        }
        return out
    }

    private static func allowedRoot(of target: [String], piece: [String]) -> [String]? {
        var roots: [[String]] = [["figures"], ["research"]]
        if piece.count == 3, piece[0] == "pieces" {
            roots.append(["pieces", piece[1], "research"])
        }
        return roots.first { root in
            target.count > root.count && Array(target.prefix(root.count)) == root
        }
    }
}
