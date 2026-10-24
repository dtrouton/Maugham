import Foundation
import MaughamCore
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers

/// Where a figure's image lives, or why it can't be used (report foundations
/// plan 2, R-P2-7).
///
/// A figure path is written relative to its piece's own file, the way a
/// Markdown editor previews it: `manuscript/ch1.md` reaches the project's
/// research as `../research/x.png`, a root-level `story.md` as
/// `research/x.png`. It is accepted only inside the project's `figures/`
/// (where an image figure's file lives, report plan 6a Task 9, reached
/// from any piece) or a research folder of the project — the project's
/// `research/`, or, for a Collection piece at `pieces/<x>/<file>`, that
/// piece's own `pieces/<x>/research/` (`ResearchScope.pieceResearchPrefix`'s
/// rule), where figure lines written before figures had a folder of their
/// own point (spec §4.4). Another piece's research folder is refused.
///
/// The order is the safety: everything that can be decided from the string —
/// an absolute path, a `~`, a URL scheme (`http:`, `file:`, `data:`), a `..`
/// that climbs out of the project, a folder that isn't figures or research — is decided
/// before the disk is touched. Only then are symlinks resolved, and the
/// resolved file must still sit under the resolved allowed folder, itself
/// under the resolved project. `resolve` stats the file and never reads a
/// byte; the compilers read it at staging (`openingProblem`, `contentHash`).
///
/// The two refusals map onto R-P2-1's two error kinds: `.notLocal` is "a
/// figure path outside figures and research", `.unreadable` is "an image that
/// can't be read" (missing, not a regular file, or a format this output
/// can't show).
public enum FigureImageResolver {

    public enum Outcome: Equatable {
        /// The resolved (symlink-free) file to stage.
        case file(URL)
        /// Not a file inside this project's `figures/` or a research folder.
        case notLocal
        /// Inside an allowed folder, but not usable; the reason is a sentence.
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
              let root = allowedRoot(of: target, piece: piece)
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
        // the containment check would misreport it as outside its folder.
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

    /// The allowed folder `target` sits strictly inside, or nil: the
    /// project's `figures/` (any piece's), the project's `research/`, or the
    /// owning Collection piece's own research.
    private static func allowedRoot(of target: [String], piece: [String]) -> [String]? {
        var roots: [[String]] = [["figures"], ["research"]]
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
    /// A resolved image's content hash (`ContentHash.ofFile`, shared with
    /// the phone): the content-addressed name both compilers stage it under
    /// (`build/figures/<hash>.<ext>` for the PDF, `OEBPS/images/<hash>.<ext>`
    /// for the EPUB), so the same image used twice is one file. Throws when
    /// the file can't be read.
    static func contentHash(of url: URL) throws -> String {
        try ContentHash.ofFile(url)
    }
}

extension FigureImageResolver {
    /// Why a resolved image won't open in a book, as a fragment that follows
    /// its path ("is an encrypted PDF, …"); nil when it will (final review
    /// M1). Read at staging, before the hash, by both compilers, so a file
    /// that would stop the typesetter or ship broken in an EPUB is an
    /// `imageUnreadable` problem naming its paragraph instead.
    ///
    /// It sniffs and never decodes pixels: ImageIO reads the header and the
    /// real type (a `.png` that is really a JPEG or HEIC is refused by name),
    /// a PNG's chunk headers are walked to its `IEND` (a cut-short PNG stops
    /// the typesetter), a PDF must open, be unencrypted and have a page, and
    /// an SVG must say `<svg` near its start. A JPEG is only header-checked:
    /// the typesetter embeds its bytes without decoding them.
    static func openingProblem(of url: URL) -> String? {
        let ext = url.pathExtension.lowercased()
        if ext == "pdf" { return pdfProblem(url) }
        if ext == "svg" { return svgProblem(url) }
        guard let expected = rasterTypes[ext] else { return nil }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), // adr-0018-ok: a figure image header sniffed
              CGImageSourceGetCount(source) > 0,
              let type = CGImageSourceGetType(source) as String?,
              CGImageSourceCopyPropertiesAtIndex(source, 0, nil) != nil
        else { return "won't open as an image (it may be damaged, or not really a .\(ext) file)" }
        guard type == expected else {
            let real = UTType(type)?.preferredFilenameExtension?.uppercased() ?? type
            return "is really a \(real) image, not a .\(ext) file"
        }
        if ext == "png", !pngReachesItsEnd(url) {
            return "is cut short (the PNG ends before its last chunk)"
        }
        return nil
    }

    /// The raster extensions either output shows, and the type ImageIO must
    /// find in the file.
    private static let rasterTypes: [String: String] = [
        "png": UTType.png.identifier, "jpg": UTType.jpeg.identifier,
        "jpeg": UTType.jpeg.identifier, "gif": UTType.gif.identifier,
    ]

    private static func pdfProblem(_ url: URL) -> String? {
        guard let document = CGPDFDocument(url as CFURL) else { // adr-0018-ok: a figure PDF opened to check it can be placed
            return "won't open as a PDF (it may be damaged or cut short)"
        }
        if document.isEncrypted { return "is an encrypted PDF, which can't be placed in a book" }
        if document.numberOfPages < 1 { return "is a PDF with no pages" }
        return nil
    }

    private static func svgProblem(_ url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "can't be read" } // adr-0018-ok: a figure SVG's opening bytes sniffed
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: 64 * 1024)) ?? Data()
        return String(decoding: head, as: UTF8.self).contains("<svg")
            ? nil : "won't open as an SVG image (no <svg> element at its start)"
    }

    /// Walks the PNG's chunk headers — length, type, then a seek past data
    /// and CRC — until `IEND`, reading 8 bytes per chunk. False when a chunk
    /// runs past the end of the file or the file ends first.
    private static func pngReachesItsEnd(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url), // adr-0018-ok: a figure PNG's chunk headers walked
              let size = try? handle.seekToEnd() else { return false }
        defer { try? handle.close() }
        var offset: UInt64 = 8   // the signature
        while offset + 12 <= size {
            guard (try? handle.seek(toOffset: offset)) != nil,
                  let header = try? handle.read(upToCount: 8), header.count == 8 else { return false }
            let length = header.prefix(4).reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
            let next = offset + 12 + length
            guard next <= size else { return false }
            if header.suffix(4) == Data("IEND".utf8) { return true }
            offset = next
        }
        return false
    }
}
