import Foundation

/// A parsed sensory-palette card. Cards are plain markdown research assets under
/// `research/palette/`. The MODEL owns the file: `PaletteCardParser` reads it and
/// `PaletteCardRenderer` writes the canonical form back, so `parse(render(card))
/// == card` for any editor-reachable model. External hand-edits are unsupported;
/// re-rendering normalizes them.
///
/// Canonical card markdown:
///
/// ```markdown
/// # The Flat
///
/// kind: location
///
/// Third-floor walk-up. Freeform body prose sits here — after `kind:`, before
/// the first `##` — and may span multiple paragraphs.
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
/// - ./the-flat_assets/image-1.png
/// ```
///
/// Title is the first `# ` heading (else the fallback). `kind:` is captured once,
/// from the first `kind:` line before any real section (unknown/missing →
/// `.other`); a later `kind:`-looking line is ordinary body prose. Everything
/// between `kind:` and the first real `##` section is `body`, preserved
/// byte-for-byte (indentation, trailing whitespace, interior blank-line runs)
/// except the single structural blank line the renderer pads around a
/// non-empty body, which is stripped on the way in and re-added on the way
/// out. `## Swatches` items must be `#RGB`/`#RRGGBB` (others
/// ignored); `## Senses` items with a leading `<sense>:` token are tagged, others
/// untagged; `## Images` items are card-relative paths, resolved to
/// project-relative; inline `![alt](path)` images anywhere are ALSO collected
/// (deduped). An unknown `##` heading BEFORE any real section is treated as body
/// text; after real structure has started it names a dropped section.
///
/// Residual we accept: a body line that exactly spells a KNOWN section name
/// (`## Swatches`) still promotes to that section rather than staying prose —
/// vanishingly unlikely typed input, and it simply converges to canonical form.
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
        var kindCaptured = false
        var imagesSectionLines: [String] = []

        for rawLine in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            let raw = String(rawLine)
            // `line` is a trimmed PROBE used only for structure detection
            // (heading/title/kind matching, `- ` item prefixes) — never for
            // body storage, so indentation and trailing whitespace typed
            // into body prose survive verbatim below.
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("## ") {
                switch line.dropFirst(3).trimmingCharacters(in: .whitespaces).lowercased() {
                case "swatches": section = .swatches; seenSectionHeading = true; continue
                case "senses": section = .senses; seenSectionHeading = true; continue
                case "images": section = .images; seenSectionHeading = true; continue
                default:
                    // An unknown `##` heading after real structure names a dropped
                    // section (model-owns-file). Before any real section it's just
                    // body prose — fall through to the body accumulation below.
                    if seenSectionHeading { section = .unknown; continue }
                }
            }
            if line.hasPrefix("# "), title == nil {
                title = String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                continue
            }
            // Capture `kind:` once, before any real section. A later `kind:`-looking
            // line is ordinary body prose and must never overwrite `kind`.
            if !kindCaptured, !seenSectionHeading, line.lowercased().hasPrefix("kind:") {
                let raw = line.dropFirst("kind:".count).trimmingCharacters(in: .whitespaces)
                kind = PaletteCard.Kind(rawValue: raw.lowercased()) ?? .other
                kindCaptured = true
                continue
            }
            // Freeform prose before the first `##` accumulates as body verbatim
            // (raw, untrimmed) — body bytes are storage, not presentation; the
            // one structural blank line the renderer pads around a non-empty
            // body is peeled off below, after the walk. The blank line the
            // renderer emits between the title and `kind:` is a SECOND piece
            // of structural framing that lands here too (it's still
            // `section == .none` and `kind:` hasn't been captured yet) — drop
            // it rather than let it masquerade as a leading body blank. Only
            // an empty (not just blank-probe) line is treated as that framing,
            // so a real pre-`kind:` prose line still falls through to body.
            if section == .none {
                if !kindCaptured, raw.isEmpty { continue }
                bodyLines.append(raw)
                continue
            }
            if section == .images {
                // Captured verbatim (dash items and prose alike) so the inline-image
                // scan below can find `![alt](path)` written as loose text in this
                // section, without also sweeping body prose (that's prose, not data).
                imagesSectionLines.append(line)
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
                if !item.contains("://") { images.append(resolve(path: item, relativeTo: cardDirectory)) }
            default:
                break  // .unknown dropped; .none is unreachable (pre-section prose
                       // is captured into `bodyLines` above and never reaches here).
            }
        }

        // Inline ![alt](path) images, but ONLY within the `## Images` section —
        // body prose keeps its `![]()` text verbatim rather than being harvested
        // (a body-typed image must stay editable/removable as prose, not become a
        // thumbnail the model can never drop). Remote URLs never enter imagePaths.
        let imagesSectionText = imagesSectionLines.joined(separator: "\n")
        for path in inlineImagePaths(in: imagesSectionText) where !path.contains("://") {
            let resolved = resolve(path: path, relativeTo: cardDirectory)
            if !images.contains(resolved) { images.append(resolved) }
        }

        // Body bytes are storage: preserved verbatim. The renderer always pads
        // a non-empty body with exactly one blank-line separator before it
        // (after `kind:`) and one after (before the next `##`) — that single
        // pair is structural framing, not body content, so it's the only
        // thing peeled off here. Any further leading/trailing blank lines the
        // writer actually typed, plus every interior blank-line run, survive
        // untouched.
        if bodyLines.first == "" { bodyLines.removeFirst() }
        if bodyLines.last == "" { bodyLines.removeLast() }
        let body = bodyLines.joined(separator: "\n")

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
