import Foundation
import CryptoKit

/// Where a figure's image lives, or why it can't be used (report foundations
/// plan 2, R-P2-7).
///
/// A figure path is written relative to its piece's own file, the way a
/// Markdown editor previews it: `manuscript/ch1.md` reaches the project's
/// research as `../research/x.png`, a root-level `story.md` as
/// `research/x.png`. It is accepted only inside a research folder of the
/// project — the project's `research/`, or, for a Collection piece at
/// `pieces/<x>/<file>`, that piece's own `pieces/<x>/research/`
/// (`ResearchScope.pieceResearchPrefix`'s rule). Another piece's research
/// folder is refused.
///
/// The order is the safety: everything that can be decided from the string —
/// an absolute path, a `~`, a URL scheme (`http:`, `file:`, `data:`), a `..`
/// that climbs out of the project, a folder that isn't research — is decided
/// before the disk is touched. Only then are symlinks resolved, and the
/// resolved file must still sit under the resolved research folder, itself
/// under the resolved project. It stats the file; it never reads a byte.
///
/// The two refusals map onto R-P2-1's two error kinds: `.notLocal` is "a
/// figure path outside a research folder", `.unreadable` is "an image that
/// can't be read" (missing, not a regular file, or a format this output
/// can't show).
public enum FigureImageResolver {

    public enum Outcome: Equatable {
        /// The resolved (symlink-free) file to stage.
        case file(URL)
        /// Not a file inside a research folder of this project.
        case notLocal
        /// Inside research, but not usable; the reason is a sentence.
        case unreadable(String)
    }

    /// - Parameters:
    ///   - path: as written in the manuscript, relative to the piece's file.
    ///     Not percent-decoded: what is written is what is looked up.
    ///   - piecePath: the piece's project-relative manuscript path
    ///     (`PublishContext.piecePaths`).
    ///   - projectURL: the REAL project (`PublishContext.projectURL`).
    ///   - allowed: the output's lowercase file extensions.
    public static func resolve(
        _ path: String, piecePath: String, projectURL: URL, allowed: Set<String>
    ) -> Outcome {
        // 1. The string alone.
        guard isRelative(path), isRelative(piecePath),
              let piece = standardised(components(piecePath)), !piece.isEmpty,
              let target = standardised(Array(piece.dropLast()) + components(path)),
              let root = researchRoot(of: target, piece: piece)
        else { return .notLocal }

        let ext = (target.last.map { ($0 as NSString).pathExtension } ?? "").lowercased()
        guard Set(allowed.map { $0.lowercased() }).contains(ext) else {
            let shown = ext.isEmpty ? "a file with no extension" : "the .\(ext) format"
            return .unreadable(
                "\(path) is \(shown), which this output can't show "
                + "(it shows \(allowed.sorted().joined(separator: ", ")))")
        }

        // 2. The disk. Existence first, on the unresolved URL (a stat that
        // follows links, so a dangling link is missing too): a missing file
        // keeps its `/private/var/…` spelling through `resolvingSymlinksInPath`
        // while its existing folders resolve to `/var/…`, so letting it reach
        // the containment check would misreport it as outside research.
        guard FileManager.default.fileExists(atPath: appending(target, to: projectURL).path) else {
            return .unreadable("there is no file at \(path)")
        }
        // Then resolve symlinks and re-check containment.
        let project = projectURL.resolvingSymlinksInPath()
        let rootURL = appending(root, to: projectURL).resolvingSymlinksInPath()
        let fileURL = appending(target, to: projectURL).resolvingSymlinksInPath()
        guard isStrictlyInside(rootURL, project), isStrictlyInside(fileURL, rootURL) else {
            return .notLocal
        }
        guard let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey]) else {
            return .unreadable("there is no file at \(path)")
        }
        guard values.isRegularFile == true else {
            return .unreadable("\(path) is not a file")
        }
        return .file(fileURL)
    }

    // MARK: - lexical

    /// No absolute path, no home-relative path, no URL scheme.
    private static func isRelative(_ path: String) -> Bool {
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

    private static func components(_ path: String) -> [String] {
        path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    }

    /// Folds `.` and `..`; nil when a `..` climbs above the project root —
    /// an escape is refused even if a later segment would climb back in.
    private static func standardised(_ parts: [String]) -> [String]? {
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

    /// The research folder `target` sits strictly inside, or nil: the
    /// project's `research/`, or the owning Collection piece's own.
    private static func researchRoot(of target: [String], piece: [String]) -> [String]? {
        var roots: [[String]] = [["research"]]
        if piece.count == 3, piece[0] == "pieces" {
            roots.append(["pieces", piece[1], "research"])
        }
        return roots.first { root in
            target.count > root.count && Array(target.prefix(root.count)) == root
        }
    }

    // MARK: - disk

    private static func appending(_ parts: [String], to base: URL) -> URL {
        parts.reduce(base) { $0.appendingPathComponent($1) }
    }

    private static func isStrictlyInside(_ url: URL, _ folder: URL) -> Bool {
        let base = folder.standardizedFileURL.path
        return url.standardizedFileURL.path.hasPrefix(base.hasSuffix("/") ? base : base + "/")
    }
}

extension FigureImageResolver {
    /// The first 16 hex digits of a resolved image's SHA-256, read in 1 MB
    /// chunks and never held whole: the content-addressed name both compilers
    /// stage it under (`build/figures/<hash>.<ext>` for the PDF,
    /// `OEBPS/images/<hash>.<ext>` for the EPUB), so the same image used twice
    /// is one file. Throws when the file can't be read.
    static func contentHash(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url) // adr-0018-ok: research image hashed for its staged name
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined().prefix(16).description
    }
}
