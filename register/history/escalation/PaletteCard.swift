import Foundation

// MARK: - Section vocabulary

/// The one place the palette card's section vocabulary AND its render order are
/// written down. Declaration order is the render order; `rawValue` is the heading
/// text as emitted. Matching is case-insensitive on the lowercased raw value, so
/// adding a case here adds the section everywhere at once.
///
/// This mirrors the discipline M1-A-16 imposes on `Sense`: no re-typed literal.
fileprivate enum PaletteSection: String, CaseIterable {
    case swatches = "Swatches"
    case senses = "Senses"
    case textures = "Textures"
    case images = "Images"

    /// The section named by a heading's text, matched case-insensitively and
    /// tolerant of surrounding whitespace (M1-C-014, M1-C-015).
    static func named(_ text: String) -> PaletteSection? {
        let key = text.trimmingCharacters(in: .whitespaces).lowercased()
        return PaletteSection.allCases.first { $0.rawValue.lowercased() == key }
    }
}

// MARK: - Model

public struct PaletteCard: Equatable, Sendable, Identifiable {

    public enum Kind: String, CaseIterable, Sendable { case location, character, motif, other }

    /// Declaration order is load-bearing for downstream grouping (M1-B-04, M1-T-048).
    public enum Sense: String, CaseIterable, Sendable, Codable { case sight, sound, smell, touch, taste }

    public struct SensoryNote: Equatable, Sendable, Codable {
        public let sense: Sense?
        public let text: String
        public init(sense: Sense?, text: String) {
            self.sense = sense
            self.text = text
        }

        /// Spelled out rather than left to synthesis: these strings become a
        /// persisted wire format, and a property rename must not silently change
        /// the sidecar's schema.
        private enum CodingKeys: String, CodingKey {
            case sense, text
        }
    }

    /// A short free-text note about how something feels, optionally prefixed with a
    /// **material tag**.
    ///
    /// Unlike `Sense`, `material` is an arbitrary string rather than a closed set.
    /// That is the whole difficulty of this type: because ANY prefix before the first
    /// colon reads back as a tag, an *untagged* note whose text happens to contain a
    /// colon (`"everything here is gritty: even the light"`) renders to a line that
    /// reads back as a TAGGED note, and `parse(render(card)) == card` fails
    /// (M1-A-01). `Sense` does not have this problem: only five specific words can be
    /// mistaken for a tag.
    ///
    /// RULING-1 therefore applies with full force, and the initialiser is FAILABLE:
    /// a `TextureNote` that could not be read back faithfully cannot be constructed.
    /// The refusal happens at the point of entry and the compiler makes every caller
    /// look at it. `problem(material:text:)` says WHY, so a UI can tell the writer.
    ///
    /// The authority for representability is not a list of rules — it is the actual
    /// round trip, executed on the actual renderer and parser helpers. Rules drift
    /// from the code they describe; this cannot.
    ///
    /// Decoding is not an exception to any of that: see the `Codable` section below,
    /// where `init(from:)` routes through this same failable initialiser.
    public struct TextureNote: Equatable, Sendable {

        /// Why a (material, text) pair was refused. Diagnostic only — the
        /// initialiser's authority is the executed round trip, and
        /// `wouldNotSurviveARoundTrip` is the honest catch-all for a pair this
        /// enumeration has not learned to name.
        public enum Problem: Equatable, Sendable {
            /// An untagged note with no text: it renders as a bare `- `, which the
            /// parser drops (M1-C-030) and the renderer must never emit (M1-T-041).
            case emptyUntaggedNote
            /// `material` was empty or whitespace-only. Use `nil` for "untagged".
            case blankMaterial
            /// `material` contains `:`, so the split would land inside the tag.
            case colonInMaterial
            /// `material` or `text` carries leading/trailing whitespace, which the
            /// parser trims away on the way back in.
            case surroundingWhitespace
            /// A line break: the note would be split across two lines and the
            /// remainder read as something else (compare the defect M1-C-045).
            case containsLineBreak
            /// An untagged note whose text would read back as a tagged one.
            case untaggedTextWouldReadBackAsTagged
            /// Refused by the executed round trip for a reason not named above.
            case wouldNotSurviveARoundTrip
        }

        public let material: String?
        public let text: String

        /// Fails when the pair cannot be written to the card and read back
        /// unchanged. See `Problem` for the reasons and RULING-1 for why this is
        /// failable at all.
        public init?(material: String?, text: String) {
            guard TextureNote.problem(material: material, text: text) == nil else { return nil }
            self.material = material
            self.text = text
        }

        /// `nil` when the pair is representable; otherwise the reason it is not.
        ///
        /// Entry points should call this to explain the refusal. It is a strict
        /// companion to `init?`: it names the common cases first and then defers to
        /// the same executed round trip the initialiser uses, so the two can never
        /// disagree about whether a pair is acceptable — only about how precisely
        /// the refusal is worded.
        public static func problem(material: String?, text: String) -> Problem? {
            if let material {
                if material.trimmingCharacters(in: .whitespaces).isEmpty { return .blankMaterial }
                if material.contains(":") { return .colonInMaterial }
                if material.contains("\n") { return .containsLineBreak }
                if material != material.trimmingCharacters(in: .whitespaces) { return .surroundingWhitespace }
            }
            if text.contains("\n") { return .containsLineBreak }
            if text != text.trimmingCharacters(in: .whitespaces) { return .surroundingWhitespace }

            guard let item = PaletteCardRenderer.textureItem(material: material, text: text) else {
                return .emptyUntaggedNote
            }
            // Validate the LINE the renderer will actually write, through the same
            // dash-item reader the parser uses, so the bare-bullet drop and the
            // item trimming are both exercised rather than described.
            guard let echoedItem = PaletteCardParser.dashItem("- " + item) else {
                return .emptyUntaggedNote
            }
            let echo = PaletteCardParser.textureFields(fromItem: echoedItem)
            guard echo.material == material, echo.text == text else {
                return material == nil ? .untaggedTextWouldReadBackAsTagged : .wouldNotSurviveARoundTrip
            }
            return nil
        }
    }

    public let researchItemId: String
    public let title: String
    public let kind: Kind
    public let swatches: [String]      // validated "#RGB" / "#RRGGBB"
    public let notes: [SensoryNote]
    public let imagePaths: [String]    // project-relative
    public let textures: [TextureNote]
    public let body: String            // freeform prose before the first `##`

    /// `textures` is deliberately NOT defaulted. Every existing construction site
    /// must fail to compile and be looked at once: a defaulted parameter would let
    /// every "rebuild this card with one field changed" call site silently erase the
    /// writer's textures, and `parse(render(card)) == card` would still hold, so no
    /// round-trip test would notice.
    public init(researchItemId: String, title: String, kind: Kind,
                swatches: [String], notes: [SensoryNote], imagePaths: [String],
                textures: [TextureNote], body: String = "") {
        self.researchItemId = researchItemId
        self.title = title
        self.kind = kind
        self.swatches = swatches
        self.notes = notes
        self.imagePaths = imagePaths
        self.textures = textures
        self.body = body
    }

    public var id: String { researchItemId }

    /// "#RRGGBB" / "#RGB" -> normalized rgb components, nil if malformed.
    public static func color(fromHex hex: String) -> (r: Double, g: Double, b: Double)? {
        guard hex.hasPrefix("#") else { return nil }
        var body = String(hex.dropFirst())
        if body.count == 3 {
            body = body.map { "\($0)\($0)" }.joined()
        }
        guard body.count == 6, let value = UInt32(body, radix: 16) else { return nil }
        let r = Double((value >> 16) & 0xFF) / 255.0
        let g = Double((value >> 8) & 0xFF) / 255.0
        let b = Double(value & 0xFF) / 255.0
        return (r: r, g: g, b: b)
    }
}

// MARK: - Codable

// The card is cached whole into the canvas's derived JSON sidecar. Two rules shape
// this conformance, and nothing else does.
//
// **1. Decoding must not construct a value the type's own initialiser would
// refuse.** `TextureNote.init?` is RULING-1 expressed in the type system; a
// synthesized decoder assigns stored properties directly and would be the only way
// in the codebase around it. So `TextureNote` decodes THROUGH `init?`.
//
// The converse matters just as much: nothing else in the model refuses anything at
// construction, so nothing else gains validation here. An invalid swatch is a
// documented defect (M1-C-043), not a refused value; a `SensoryNote` that reads back
// tagged is a documented defect (M1-C-053), not a refused value. Decoding is a read
// path, not the place to tighten the model — tightening belongs in the initialisers,
// where every caller has to look at it.
//
// **2. A file that arrives is read tolerantly** (RULING-2). The sidecar is derived
// and its authority is the card's markdown, so a texture note that fails rule 1 is
// DROPPED, exactly as the parser drops the same content in `case .section(.textures)`
// — not thrown, which would cost a whole cached scene for one unreadable note.
//
// The coding keys are spelled out everywhere rather than left to synthesis: they are
// a persisted wire format, and a property rename must not silently reshape the
// sidecar's schema.

extension PaletteCard: Codable {

    private enum CodingKeys: String, CodingKey {
        case researchItemId, title, kind, swatches, notes, imagePaths, textures, body
    }

    /// Decodes a texture note without throwing, so one unreadable note costs only
    /// itself.
    ///
    /// The `try?` sits inside the ELEMENT's own initialiser rather than around an
    /// `UnkeyedDecodingContainer.decode` call, because a container is not guaranteed
    /// to advance past an element whose decode threw — that shape loops forever on
    /// the first bad element.
    private struct LenientTextureNote: Decodable {
        let note: TextureNote?
        init(from decoder: any Decoder) throws {
            note = try? TextureNote(from: decoder)
        }
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let textures = try container.decode([LenientTextureNote].self, forKey: .textures)
        // Through the memberwise initialiser, not by assigning stored properties, so
        // construction keeps one path.
        self.init(researchItemId: try container.decode(String.self, forKey: .researchItemId),
                  title: try container.decode(String.self, forKey: .title),
                  kind: try container.decode(Kind.self, forKey: .kind),
                  swatches: try container.decode([String].self, forKey: .swatches),
                  notes: try container.decode([SensoryNote].self, forKey: .notes),
                  imagePaths: try container.decode([String].self, forKey: .imagePaths),
                  textures: textures.compactMap(\.note),
                  body: try container.decode(String.self, forKey: .body))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(researchItemId, forKey: .researchItemId)
        try container.encode(title, forKey: .title)
        try container.encode(kind, forKey: .kind)
        try container.encode(swatches, forKey: .swatches)
        try container.encode(notes, forKey: .notes)
        try container.encode(imagePaths, forKey: .imagePaths)
        try container.encode(textures, forKey: .textures)
        try container.encode(body, forKey: .body)
    }
}

extension PaletteCard.Kind: Codable {

    /// An unrecognised kind degrades to `.other` rather than failing the decode,
    /// which is exactly what the other reader of this field already does with an
    /// unrecognised `kind:` line (M1-T-012). `.other` is the member this type
    /// already declares for "I do not know what this is", so the degrade invents
    /// nothing and loses nothing a future case could not restore.
    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = PaletteCard.Kind(rawValue: raw) ?? .other
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

extension PaletteCard.TextureNote: Codable {

    private enum CodingKeys: String, CodingKey {
        case material, text
    }

    /// Routes through `init?`, so a decoded note is one the writer could have made
    /// (RULING-1). The failure names the `Problem`, so a corrupt sidecar reads like
    /// the entry-point refusal it mirrors rather than like a generic type error.
    ///
    /// This throws rather than dropping because a single note cannot drop itself;
    /// the drop happens one level up, in `PaletteCard.LenientTextureNote`, where
    /// there is a collection to leave a gap in.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let material = try container.decodeIfPresent(String.self, forKey: .material)
        let text = try container.decode(String.self, forKey: .text)
        guard let note = PaletteCard.TextureNote(material: material, text: text) else {
            let reason = Self.problem(material: material, text: text).map { "\($0)" }
                ?? "wouldNotSurviveARoundTrip"
            throw DecodingError.dataCorruptedError(
                forKey: .text, in: container,
                debugDescription: "Texture note could not be read back faithfully: \(reason)")
        }
        self = note
    }

    /// `encodeIfPresent`: an untagged note omits the key rather than writing null,
    /// and the decoder reads either form back as `nil`.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(material, forKey: .material)
        try container.encode(text, forKey: .text)
    }
}

// MARK: - Parser

public enum PaletteCardParser {

    private enum Region: Equatable {
        case preamble
        case section(PaletteSection)
        case discarded
    }

    public static func template(title: String, kind: PaletteCard.Kind) -> String {
        var out = "# \(title)\n\nkind: \(kind.rawValue)\n"
        for section in PaletteSection.allCases {
            out += "\n## \(section.rawValue)\n"
        }
        return out
    }

    public static func parse(markdown: String, itemId: String,
                             fallbackTitle: String, cardDirectory: String) -> PaletteCard {
        var title: String?
        var kind: PaletteCard.Kind = .other
        var kindCaptured = false
        var swatches: [String] = []
        var notes: [PaletteCard.SensoryNote] = []
        var textures: [PaletteCard.TextureNote] = []
        var images: [String] = []
        var imageProse: [String] = []
        var bodyLines: [String] = []
        var region: Region = .preamble
        var sawSection = false

        // `split(separator: Character)` — NOT `components(separatedBy:)`. Swift
        // treats "\r\n" as one Character, so a CRLF document parses as one line
        // (M1-C-024, an accepted limit). `omittingEmptySubsequences: false` is what
        // preserves blank lines inside body.
        for rawSlice in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            let raw = String(rawSlice)
            // Structure is detected on the TRIMMED probe; storage uses the raw line
            // (M1-A-18, M1-C-016).
            let probe = raw.trimmingCharacters(in: .whitespaces)

            if let level = headingLevel(probe) {
                let heading = headingText(probe, level: level)

                if title == nil, level == 1, !heading.isEmpty {
                    title = heading
                    continue
                }
                if level == 2, let section = PaletteSection.named(heading) {
                    region = .section(section)
                    sawSection = true
                    continue
                }
                if sawSection {
                    // An unknown heading after real structure discards itself and
                    // everything under it, up to the next heading (M1-C-039).
                    region = .discarded
                    continue
                }
                // Before any real structure an unknown heading is body, heading line
                // included (M1-C-038), so fall through.
            }

            switch region {
            case .discarded:
                continue

            case .preamble:
                if !kindCaptured, probe.lowercased().hasPrefix("kind:") {
                    let value = String(probe.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                    kind = PaletteCard.Kind(rawValue: value) ?? .other
                    kindCaptured = true
                    // The blank line the writer typed above `kind:` is structural
                    // framing and is eaten; a whitespace-bearing line survives,
                    // because the test is `== ""` (M1-C-023).
                    if bodyLines.last == "" { bodyLines.removeLast() }
                    continue
                }
                bodyLines.append(raw)

            case .section(.swatches):
                guard let item = dashItem(probe) else { continue }
                // Stored exactly as written: neither deduplicated, case-normalised
                // nor expanded (M1-C-025, M1-C-026).
                guard PaletteCard.color(fromHex: item) != nil else { continue }
                swatches.append(item)

            case .section(.senses):
                guard let item = dashItem(probe) else { continue }
                notes.append(sensoryNote(fromItem: item))

            case .section(.textures):
                guard let item = dashItem(probe) else { continue }
                let fields = textureFields(fromItem: item)
                // A refusal here can only mean the file holds something this model
                // cannot read back faithfully, which RULING-2 permits us to drop.
                // Parser output is canonical by construction, so this never fires
                // in practice — it fires if that ever stops being true.
                guard let note = PaletteCard.TextureNote(material: fields.material,
                                                         text: fields.text) else { continue }
                textures.append(note)

            case .section(.images):
                guard let item = dashItem(probe) else {
                    imageProse.append(raw)
                    continue
                }
                guard !item.contains("://") else { continue }   // M1-C-034, M1-A-06
                images.append(resolve(item, in: cardDirectory)) // not deduped (M1-C-031)
            }
        }

        // Inline images written as loose prose inside the Images section are
        // harvested AFTER the dash items (M1-T-008, M1-T-021) and ARE deduplicated
        // against what is already collected (M1-C-032). Body prose is never scanned
        // (M1-A-05, M1-T-017). The shared matcher is the only matcher (M1-A-15).
        for found in MarkdownBlockParser.findInlineImages(in: imageProse.joined(separator: "\n")) {
            guard !found.path.contains("://") else { continue }  // M1-T-019, M1-A-06
            let resolved = resolve(found.path, in: cardDirectory)
            guard !images.contains(resolved) else { continue }
            images.append(resolved)
        }

        // Exactly one leading and one trailing EMPTY line is the renderer's
        // structural pad; anything beyond that pair is the writer's (M1-T-025,
        // M1-T-026). The test is `== ""`, not blankness (M1-C-009).
        if bodyLines.first == "" { bodyLines.removeFirst() }
        if bodyLines.last == "" { bodyLines.removeLast() }

        return PaletteCard(researchItemId: itemId,
                           title: title ?? fallbackTitle,
                           kind: kind,
                           swatches: swatches,
                           notes: notes,
                           imagePaths: images,
                           textures: textures,
                           body: bodyLines.joined(separator: "\n"))
    }

    // MARK: Line readers

    /// The number of leading `#` characters when the probe is a heading — that is,
    /// when the hashes are followed by a space (M1-C-012, M1-C-017). `nil` otherwise.
    private static func headingLevel(_ probe: String) -> Int? {
        var level = 0
        var index = probe.startIndex
        while index < probe.endIndex, probe[index] == "#" {
            level += 1
            index = probe.index(after: index)
        }
        guard level > 0, index < probe.endIndex, probe[index] == " " else { return nil }
        return level
    }

    private static func headingText(_ probe: String, level: Int) -> String {
        String(probe.dropFirst(level)).trimmingCharacters(in: .whitespaces)
    }

    /// The item text of a `- ` bullet, or `nil` when the line is not a bullet or is
    /// a bare `-` / `- ` (M1-C-030).
    static func dashItem(_ probe: String) -> String? {
        guard probe == "-" || probe.hasPrefix("- ") else { return nil }
        let item = String(probe.dropFirst(probe == "-" ? 1 : 2))
            .trimmingCharacters(in: .whitespaces)
        return item.isEmpty ? nil : item
    }

    /// `<sense>: text` yields a tagged note; anything else keeps the WHOLE item
    /// text, colon included (M1-T-005, M1-T-006, M1-C-027, M1-C-028, M1-C-029).
    private static func sensoryNote(fromItem item: String) -> PaletteCard.SensoryNote {
        if let colon = item.firstIndex(of: ":") {
            let token = item[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            if !token.isEmpty, let sense = PaletteCard.Sense(rawValue: token) {
                let text = String(item[item.index(after: colon)...])
                    .trimmingCharacters(in: .whitespaces)
                return PaletteCard.SensoryNote(sense: sense, text: text)
            }
        }
        return PaletteCard.SensoryNote(sense: nil, text: item.trimmingCharacters(in: .whitespaces))
    }

    /// Splits a texture item at its FIRST colon. Unlike the sense reader there is no
    /// vocabulary to check against, so any non-empty prefix is a material tag; a
    /// leading colon means untagged and the colon is kept, mirroring M1-C-028.
    ///
    /// Splitting at the first colon (not the last) is what makes a tagged note whose
    /// TEXT contains colons round-trip: `slate: cold: damp` reads back as
    /// ("slate", "cold: damp") and renders identically.
    static func textureFields(fromItem item: String) -> (material: String?, text: String) {
        if let colon = item.firstIndex(of: ":") {
            let token = item[..<colon].trimmingCharacters(in: .whitespaces)
            if !token.isEmpty {
                let text = String(item[item.index(after: colon)...])
                    .trimmingCharacters(in: .whitespaces)
                return (material: token, text: text)
            }
        }
        return (material: nil, text: item.trimmingCharacters(in: .whitespaces))
    }

    // MARK: Paths

    /// Card-relative -> project-relative. Absolute paths pass through unchanged
    /// (M1-C-033); `.` and `..` collapse in place (M1-C-036); climbing above the
    /// project root clamps rather than fails (M1-C-035); an empty directory leaves a
    /// relative path bare (M1-C-037).
    private static func resolve(_ path: String, in directory: String) -> String {
        guard !path.hasPrefix("/") else { return path }
        var components = directory.split(separator: "/").map(String.init)
        for segment in path.split(separator: "/") {
            switch segment {
            case ".":
                continue
            case "..":
                if !components.isEmpty { components.removeLast() }
            default:
                components.append(String(segment))
            }
        }
        return components.joined(separator: "/")
    }
}

// MARK: - Renderer

public enum PaletteCardRenderer {

    public static func render(_ card: PaletteCard, cardDirectory: String) -> String {
        var out: [String] = []
        out.append("# \(card.title)")
        out.append("")
        out.append("kind: \(card.kind.rawValue)")
        out.append("")

        if !card.body.isEmpty {
            out.append(contentsOf: card.body
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map(String.init))
            out.append("")
        }

        for section in PaletteSection.allCases {
            out.append("## \(section.rawValue)")
            out.append("")
            out.append(contentsOf: items(for: section, of: card, cardDirectory: cardDirectory))
            out.append("")
        }

        return out.joined(separator: "\n")
    }

    /// Project-relative -> card-relative. One `../` per uncommon component of
    /// `directory`, comparing PATH components rather than string prefixes
    /// (M1-C-052), and comparing against the path's parent so a path equal to the
    /// directory climbs out and comes back in (M1-C-048).
    public static func relativize(_ path: String, from directory: String) -> String {
        let pathComponents = path.split(separator: "/").map(String.init)
        let last = pathComponents.last
        let pathDirectory = Array(pathComponents.dropLast())
        let directoryComponents = directory.split(separator: "/").map(String.init)

        var common = 0
        while common < pathDirectory.count,
              common < directoryComponents.count,
              pathDirectory[common] == directoryComponents[common] {
            common += 1
        }

        var remainder = Array(pathDirectory[common...])
        if let last { remainder.append(last) }
        let tail = remainder.joined(separator: "/")

        let climbs = directoryComponents.count - common
        guard climbs > 0 else { return "./" + tail }
        return String(repeating: "../", count: climbs) + tail
    }

    // MARK: Items

    private static func items(for section: PaletteSection,
                              of card: PaletteCard,
                              cardDirectory: String) -> [String] {
        switch section {
        case .swatches:
            // Uppercased regardless of the model's case (M1-T-036). An invalid
            // swatch is still written and is lost on the way back in — the known
            // defect M1-C-043, preserved deliberately. Blank entries are skipped
            // because a bare `- ` must never be emitted (M1-T-041).
            return card.swatches
                .map { $0.uppercased() }
                .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                .map { "- \($0)" }

        case .senses:
            return card.notes.compactMap { note in
                if let sense = note.sense {
                    return "- \(sense.rawValue): \(note.text)"   // M1-A-10, M1-T-044
                }
                guard !note.text.trimmingCharacters(in: .whitespaces).isEmpty else {
                    return nil                                   // M1-A-09, M1-T-042
                }
                return "- \(note.text)"
            }

        case .textures:
            return card.textures.compactMap { note in
                guard let item = textureItem(material: note.material, text: note.text) else {
                    return nil
                }
                return "- \(item)"
            }

        case .images:
            return card.imagePaths.compactMap { path in
                let relative = relativize(path, from: cardDirectory)
                guard !relative.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
                return "- \(relative)"
            }
        }
    }

    /// The item text for a texture note, or `nil` when it must be dropped.
    ///
    /// A tagged note is always written, even with empty text — `- slate: ` reads
    /// back as ("slate", ""), exactly as `- smell: ` does for a sense (M1-A-10). An
    /// untagged note with no visible text would render as a bare `- `, which the
    /// renderer must never emit (M1-T-041) and the parser would drop (M1-C-030), so
    /// it is dropped here instead (M1-A-09's rule, applied to the new section).
    ///
    /// `TextureNote.init?` refuses such a note outright, so this drop is unreachable
    /// through the model. It stays because it is the renderer's own guarantee, and
    /// because it is the definition `TextureNote.problem` validates against.
    static func textureItem(material: String?, text: String) -> String? {
        if let material {
            return "\(material): \(text)"
        }
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return text
    }
}
