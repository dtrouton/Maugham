import Foundation

/// The `canvas.md` format — the one place scrap *content* lives.
///
/// Scraps are plain text on disk (spec §3.2) so a writer can read them in any
/// editor forever. Positions live in the sidecar; the words do not. This file
/// sits at PROJECT ROOT, deliberately not under `research/`: §3.2 requires that
/// scraps do not appear in the research tree, and `research/` is where the tree
/// looks.
public enum ScrapText {

    /// Marks the file as Maugham's. Purely informational — the parser tolerates
    /// its absence, because a writer may well have edited the file by hand.
    public static let banner = "<!-- maugham:canvas-scraps -->"

    /// A scrap body line that would otherwise read as a scrap heading gets one
    /// space of indent on the way out, removed on the way in. Without this, a
    /// scrap whose text begins "## something" splits into two scraps on reload.
    ///
    /// The test is "does it read as a heading once its leading spaces are
    /// stripped", NOT "does it start with `## `". Both halves use the same test,
    /// so the pair is a bijection on every input. Keying the unescape on the
    /// literal `" ## "` instead would eat a space the writer typed, silently, on
    /// the one line where they had already indented a heading themselves.
    private static func readsAsHeading(_ line: some StringProtocol) -> Bool {
        line.drop(while: { $0 == " " }).hasPrefix("## ")
    }

    private static func escape(_ body: String) -> String {
        body.split(separator: "\n", omittingEmptySubsequences: false)
            .map { readsAsHeading($0) ? " " + $0 : String($0) }
            .joined(separator: "\n")
    }

    private static func unescape(_ body: String) -> String {
        body.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.hasPrefix(" ") && readsAsHeading($0) ? String($0.dropFirst()) : String($0) }
            .joined(separator: "\n")
    }

    /// Deterministic: scraps are emitted in id order so that saving an
    /// unchanged canvas produces a byte-identical file.
    public static func render(_ scraps: [CanvasNodeID: String]) -> String {
        var out = [banner, ""]
        for id in scraps.keys.sorted(by: { $0.raw < $1.raw }) {
            out.append("## \(id.raw)")
            out.append("")
            out.append(escape(scraps[id] ?? ""))
            out.append("")
        }
        return out.joined(separator: "\n")
    }

    public static func parse(_ markdown: String) -> [CanvasNodeID: String] {
        var result: [CanvasNodeID: String] = [:]
        var currentID: CanvasNodeID?
        var body: [String] = []

        func flush() {
            guard let id = currentID else { return }
            // Trim only the blank lines the renderer added around the body. An
            // empty scrap therefore survives as "" rather than vanishing.
            var lines = body
            while lines.first?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeFirst() }
            while lines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeLast() }
            result[id] = unescape(lines.joined(separator: "\n"))
            body = []
        }

        for line in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("## ") {
                flush()
                let raw = line.dropFirst(3).trimmingCharacters(in: .whitespaces)
                currentID = raw.isEmpty ? nil : CanvasNodeID(raw)
            } else if currentID != nil {
                body.append(String(line))
            }
            // Anything before the first heading is preamble and is dropped —
            // the file may have been hand-edited.
        }
        flush()
        return result
    }
}
