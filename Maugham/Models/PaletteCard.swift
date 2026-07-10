import Foundation

/// A parsed sensory-palette card. Cards are plain markdown research assets under
/// `research/palette/`; this type is the READ model — cards are edited as raw
/// markdown, so there is no renderer (`template(title:kind:)` seeds new cards).
///
/// Card markdown convention:
///
/// ```markdown
/// # The Flat
///
/// kind: location
///
/// ## Swatches
///
/// - #8A6F4D
/// - #2F3B4C
///
/// ## Senses
///
/// - smell: turpentine and cold ash
/// - sound: tram-rattle through the shutters
/// - cold quarry tile underfoot
///
/// ## Images
///
/// - ../paris-flat.jpg
/// ```
///
/// Title is the first `# ` heading (else the fallback); `kind:` appears anywhere
/// before the first `##` (unknown/missing → `.other`); `## Swatches` items must
/// be `#RGB`/`#RRGGBB` (others ignored); `## Senses` items with a leading
/// `<sense>:` token are tagged, others untagged; `## Images` items are paths
/// relative to the card's directory, resolved to project-relative; inline
/// `![alt](path)` images anywhere in the body are ALSO collected (deduped).
/// Unknown sections are ignored.
public struct PaletteCard: Equatable, Sendable, Identifiable {
    public enum Kind: String, CaseIterable, Sendable {
        case location, character, motif, other
    }
    public enum Sense: String, CaseIterable, Sendable {
        case sight, sound, smell, touch, taste
    }
    public struct SensoryNote: Equatable, Sendable {
        public let sense: Sense?
        public let text: String
        public init(sense: Sense?, text: String) {
            self.sense = sense
            self.text = text
        }
    }

    public let researchItemId: String
    public let title: String
    public let kind: Kind
    public let swatches: [String]      // validated "#RGB" / "#RRGGBB"
    public let notes: [SensoryNote]
    public let imagePaths: [String]    // project-relative
    public let body: String            // freeform prose before the first `##`

    public init(
        researchItemId: String, title: String, kind: Kind,
        swatches: [String], notes: [SensoryNote], imagePaths: [String],
        body: String = ""
    ) {
        self.researchItemId = researchItemId
        self.title = title
        self.kind = kind
        self.swatches = swatches
        self.notes = notes
        self.imagePaths = imagePaths
        self.body = body
    }

    public var id: String { researchItemId }

    /// "#RRGGBB" / "#RGB" → normalized rgb components, nil if malformed.
    public static func color(fromHex hex: String) -> (r: Double, g: Double, b: Double)? {
        guard hex.hasPrefix("#") else { return nil }
        var body = String(hex.dropFirst())
        if body.count == 3 { body = body.map { "\($0)\($0)" }.joined() }
        guard body.count == 6, let value = UInt32(body, radix: 16) else { return nil }
        return (Double((value >> 16) & 0xFF) / 255,
                Double((value >> 8) & 0xFF) / 255,
                Double(value & 0xFF) / 255)
    }
}

public enum PaletteCardParser {

    public static func template(title: String, kind: PaletteCard.Kind) -> String {
        """
        # \(title)

        kind: \(kind.rawValue)

        ## Swatches

        ## Senses

        ## Images

        """
    }

    public static func parse(
        markdown: String, itemId: String, fallbackTitle: String, cardDirectory: String
    ) -> PaletteCard {
        var title: String?
        var kind: PaletteCard.Kind = .other
        var swatches: [String] = []
        var notes: [PaletteCard.SensoryNote] = []
        var images: [String] = []
        var bodyLines: [String] = []

        enum Section { case none, swatches, senses, images, unknown }
        var section: Section = .none
        var seenSectionHeading = false

        for rawLine in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("## ") {
                seenSectionHeading = true
                switch line.dropFirst(3).trimmingCharacters(in: .whitespaces).lowercased() {
                case "swatches": section = .swatches
                case "senses": section = .senses
                case "images": section = .images
                default: section = .unknown
                }
                continue
            }
            if line.hasPrefix("# "), title == nil {
                title = String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                continue
            }
            if !seenSectionHeading, line.lowercased().hasPrefix("kind:") {
                let raw = line.dropFirst("kind:".count).trimmingCharacters(in: .whitespaces)
                kind = PaletteCard.Kind(rawValue: raw.lowercased()) ?? .other
                continue
            }
            // Freeform prose before the first `##` accumulates as body (blanks kept
            // so paragraph breaks survive; collapsed after the walk).
            if section == .none {
                bodyLines.append(line)
                continue
            }
            guard line.hasPrefix("- ") else { continue }
            let item = String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            switch section {
            case .swatches:
                if PaletteCard.color(fromHex: item) != nil { swatches.append(item) }
            case .senses:
                if let colon = item.firstIndex(of: ":"),
                   let sense = PaletteCard.Sense(
                       rawValue: item[..<colon].trimmingCharacters(in: .whitespaces).lowercased()) {
                    let text = item[item.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                    notes.append(.init(sense: sense, text: text))
                } else {
                    notes.append(.init(sense: nil, text: item))
                }
            case .images:
                images.append(resolve(path: item, relativeTo: cardDirectory))
            case .none, .unknown:
                break
            }
        }

        // Inline ![alt](path) images anywhere in the body, deduped against section images.
        for path in inlineImagePaths(in: markdown) {
            let resolved = resolve(path: path, relativeTo: cardDirectory)
            if !images.contains(resolved) { images.append(resolved) }
        }

        // Collapse the captured body: runs of blank lines become paragraph
        // breaks (`\n\n`), adjacent non-blank lines join with `\n`.
        var body = ""
        var pendingBreak = false
        for line in bodyLines {
            if line.isEmpty {
                if !body.isEmpty { pendingBreak = true }
            } else {
                if body.isEmpty {
                    body = line
                } else {
                    body += pendingBreak ? "\n\n" : "\n"
                    body += line
                }
                pendingBreak = false
            }
        }

        return PaletteCard(
            researchItemId: itemId,
            title: title ?? fallbackTitle,
            kind: kind,
            swatches: swatches,
            notes: notes,
            imagePaths: images,
            body: body)
    }

    /// Extract the `path` from every `![alt](path)` in document order. Uses
    /// `NSRegularExpression` because bare-slash regex literals are off in the
    /// Mac target's Swift 5.10 language mode.
    private static let inlineImageRegex = try! NSRegularExpression(
        pattern: "!\\[[^\\]]*\\]\\(([^)]+)\\)")

    private static func inlineImagePaths(in markdown: String) -> [String] {
        let range = NSRange(markdown.startIndex..., in: markdown)
        return inlineImageRegex.matches(in: markdown, range: range).compactMap { match in
            guard let captured = Range(match.range(at: 1), in: markdown) else { return nil }
            return String(markdown[captured])
        }
    }

    /// Resolve a card-relative path ("../x.jpg", "y.jpg") to project-relative,
    /// collapsing "..". Absolute paths and URLs pass through unchanged.
    private static func resolve(path: String, relativeTo directory: String) -> String {
        guard !path.hasPrefix("/"), !path.contains("://") else { return path }
        var components = directory.split(separator: "/").map(String.init)
        for part in path.split(separator: "/") {
            switch part {
            case "..": if !components.isEmpty { components.removeLast() }
            case ".": continue
            default: components.append(String(part))
            }
        }
        return components.joined(separator: "/")
    }
}

/// The exact inverse of `PaletteCardParser`: renders a `PaletteCard` back to its
/// canonical markdown. `parse(render(card)) == card` for editor-reachable models.
/// The model owns the file, so rendering normalizes to canonical form (uppercase
/// swatches, card-relative `./` image paths, the three sections always present).
public enum PaletteCardRenderer {
    public static func render(_ card: PaletteCard, cardDirectory: String) -> String {
        var out = "# \(card.title)\n\nkind: \(card.kind.rawValue)\n"
        if !card.body.isEmpty { out += "\n\(card.body)\n" }
        out += "\n## Swatches\n\n"
        for s in card.swatches { out += "- \(s.uppercased())\n" }
        out += "\n## Senses\n\n"
        for n in card.notes {
            out += n.sense.map { "- \($0.rawValue): \(n.text)\n" } ?? "- \(n.text)\n"
        }
        out += "\n## Images\n\n"
        for p in card.imagePaths { out += "- \(relativize(p, from: cardDirectory))\n" }
        return out
    }

    /// Inverse of the parser's `resolve`: a project-relative path becomes
    /// card-relative — `./x` for paths under `directory`, else `../`-climbing.
    public static func relativize(_ path: String, from directory: String) -> String {
        let dirParts = directory.split(separator: "/").map(String.init)
        let pathParts = path.split(separator: "/").map(String.init)
        var common = 0
        while common < dirParts.count && common < pathParts.count - 1
                && dirParts[common] == pathParts[common] { common += 1 }
        let climbs = dirParts.count - common
        let rest = pathParts[common...].joined(separator: "/")
        return climbs == 0 ? "./\(rest)"
            : String(repeating: "../", count: climbs) + rest
    }
}
