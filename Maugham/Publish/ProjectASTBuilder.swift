import Foundation

public enum ProjectASTBuilder {

    public struct PieceRef: Sendable {
        public let pieceID: String
        public let title: String
        public let mode: ProjectAST.Mode
        public let displayText: String

        public init(pieceID: String, title: String,
                    mode: ProjectAST.Mode, displayText: String) {
            self.pieceID = pieceID
            self.title = title
            self.mode = mode
            self.displayText = displayText
        }
    }

    public protocol Source {
        func orderedPieces() -> [PieceRef]
    }

    public static func build(from source: Source) -> ProjectAST {
        let sections = source.orderedPieces().map(buildSection(from:))
        return ProjectAST(sections: sections)
    }

    // MARK: - section assembly

    private static func buildSection(from piece: PieceRef) -> ProjectAST.Section {
        let nodes: [ProjectAST.Node]
        switch piece.mode {
        case .prose:
            nodes = parseProse(piece.displayText)
        case .fountain:
            nodes = parseFountain(piece.displayText)
        }
        return .init(pieceID: piece.pieceID, title: piece.title,
                     mode: piece.mode, nodes: nodes)
    }

    // MARK: - prose

    private static func parseProse(_ text: String) -> [ProjectAST.Node] {
        // Strip inline <!-- ¶XXXX --> anchors before parsing.
        let stripped = stripAnchors(text)
        // Split on blank lines.
        let blocks = stripped
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        return blocks.map { block -> ProjectAST.Node in
            if isSceneBreakLine(block) { return .sceneBreak }
            return .paragraph(block)
        }
    }

    private static func stripAnchors(_ s: String) -> String {
        // <!-- ¶XXXX --> anchors (4-char alphabet-restricted ParagraphID).
        // Also handles <!--t-XXXXXX--> task anchors.
        var result = s
        let patterns = [
            #"<!--\s*¶[0-9a-z]{4}\s*-->"#,
            #"<!--t-[0-9a-zA-Z]{6}-->"#
        ]
        for pat in patterns {
            if let regex = try? NSRegularExpression(pattern: pat) {
                let range = NSRange(result.startIndex..., in: result)
                result = regex.stringByReplacingMatches(
                    in: result, range: range, withTemplate: "")
            }
        }
        return result
    }

    private static func isSceneBreakLine(_ s: String) -> Bool {
        let stripped = s.replacingOccurrences(of: " ", with: "")
        return stripped == "***" || stripped == "###" || stripped == "---"
    }

    // MARK: - fountain

    private static func parseFountain(_ text: String) -> [ProjectAST.Node] {
        // Best-effort line classification — full fidelity comes via
        // Maugham/Editor's existing FountainParser, which v1's builder
        // bridges through in production (see Task 31). For tests with
        // fixture text, we use this inline classifier.
        // Strip inline <!-- ¶XXXX --> anchors before parsing, exactly as
        // parseProse does — otherwise op-log join keys leak into rendered
        // screenplay output (action/dialogue text).
        let stripped = stripAnchors(text)
        var nodes: [ProjectAST.FountainNode] = []
        let lines = stripped.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)

        var i = 0
        while i < lines.count {
            let line = lines[i].trimmingCharacters(in: .whitespaces)
            defer { i += 1 }
            if line.isEmpty { continue }

            if isSceneHeading(line) {
                nodes.append(.sceneHeading(line))
            } else if isCharacter(line) {
                nodes.append(.character(line))
                // Look ahead for parenthetical + dialogue.
                while i + 1 < lines.count {
                    let next = lines[i + 1].trimmingCharacters(in: .whitespaces)
                    if next.isEmpty { break }
                    if next.hasPrefix("(") && next.hasSuffix(")") {
                        nodes.append(.parenthetical(next))
                    } else if isCharacter(next) || isSceneHeading(next) {
                        break
                    } else {
                        nodes.append(.dialogue(next))
                    }
                    i += 1
                }
            } else if line.uppercased() == line && line.hasSuffix("TO:") {
                nodes.append(.transition(line))
            } else {
                nodes.append(.action(line))
            }
        }

        return nodes.map { ProjectAST.Node.fountain($0) }
    }

    private static func isSceneHeading(_ line: String) -> Bool {
        let upper = line.uppercased()
        return upper.hasPrefix("INT.") || upper.hasPrefix("EXT.") ||
               upper.hasPrefix("INT ")  || upper.hasPrefix("EXT ")  ||
               upper.hasPrefix("INT/EXT") || upper.hasPrefix("I/E")
    }

    private static func isCharacter(_ line: String) -> Bool {
        guard !line.isEmpty else { return false }
        // ALL-CAPS lines (allowing digits, spaces, punctuation) with no
        // sentence-ending punctuation are character cues.
        let letters = line.filter { $0.isLetter }
        guard !letters.isEmpty else { return false }
        return letters == letters.uppercased() && !line.contains(".")
    }
}
