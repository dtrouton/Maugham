import Foundation

/// A named person in the project's publish department — a translator into one
/// language, or the book's designer (the publish-department milestone).
///
/// Shaped like `ReviewPass` because it earns the same machinery: a preset
/// identity and doctrine a project gets for free, a stored entry that lets the
/// writer rename or re-brief without a migration, and `effective*` resolution
/// that is spelled **once**. The `ReviewPass` lesson carries over verbatim:
/// **never read `name` or `brief` at a call site** — read `effectiveName` /
/// `effectiveBrief`, or a project that has customized nothing shows a surface
/// with a blank where a person's name should be.
///
/// Identity is `id`, minted once and stable: annotations authored by a
/// translator, and design proposals authored by the designer, are the artifacts
/// this identity signs, so a rename must not orphan them.
public struct ProductionRole: Codable, Equatable, Identifiable, Sendable {

    /// What this person *does*.
    ///
    /// **On-disk shape: a single JSON string.** `"designer"` for the designer;
    /// `"translator:<languageTag>"` for a translator. The split is on the FIRST
    /// colon, so a language tag containing one survives whole; the tag is
    /// otherwise opaque here. Any other string — including `"translator:"` with
    /// no tag, which would otherwise mint a translator matching no edition while
    /// looking valid — decodes to `.unknown(raw)` and re-encodes as that same
    /// raw string.
    ///
    /// ADR-0015 safe round-trip, the `Statement.Scope` shape: `role` is
    /// identity-bearing, so an unrecognised (future) value is preserved verbatim
    /// rather than degraded to a default. Flattening an unknown role to
    /// `.designer` would hand one person's work to another; nothing looks up
    /// `.unknown`, so such a role is retained and ignored.
    public enum Role: Codable, Equatable, Sendable {
        case translator(language: String)
        case designer
        /// A role written by a newer build. Carries the original raw string so
        /// re-encode is lossless (see type doc).
        case unknown(String)

        private static let designerRaw = "designer"
        private static let translatorPrefix = "translator:"

        /// The stable on-disk string (see type doc for the grammar).
        public var rawValue: String {
            switch self {
            case .designer: return Self.designerRaw
            case .translator(let language): return Self.translatorPrefix + language
            case .unknown(let raw): return raw
            }
        }

        public init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            if raw == Self.designerRaw {
                self = .designer
            } else if raw.hasPrefix(Self.translatorPrefix) {
                let language = String(raw.dropFirst(Self.translatorPrefix.count))
                self = language.isEmpty ? .unknown(raw) : .translator(language: language)
            } else {
                self = .unknown(raw)
            }
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(rawValue)
        }
    }

    /// Stable identity, minted once. A rename changes `name`, never this.
    public let id: String
    public var role: Role

    /// This person's name — Tschichold, Cortázar, or whatever the writer renamed
    /// them to. Own field wins; a role with none of its own falls back through
    /// `effectiveName`, never read directly at a call site.
    public var name: String?

    /// This person's standing brief — what they attend to and what they leave
    /// alone. Own field wins; falls back through `effectiveBrief`, never read
    /// directly at a call site.
    public var brief: String?

    public init(id: String, role: Role, name: String? = nil, brief: String? = nil) {
        self.id = id
        self.role = role
        self.name = name
        self.brief = brief
    }

    /// The name a reader should actually use: this role's own `name`, else the
    /// preset for what it does — Tschichold for the designer, the preset
    /// translator for this language — else, for a language with no preset and no
    /// name yet, the language tag uppercased. Never nil and never empty: a desk
    /// row and an annotation byline both need *something* to print, and a blank
    /// there reads as a bug rather than as an unnamed person. **The ONE spelling
    /// of resolution** — do not re-derive it at a call site.
    public var effectiveName: String {
        if let name, !name.isEmpty { return name }
        switch role {
        case .designer:
            return Self.designerName
        case .translator(let language):
            if let preset = Self.defaultTranslatorName(language: language) { return preset }
            let tag = language.uppercased()
            return tag.isEmpty ? Self.unnamedFallback : tag
        case .unknown(let raw):
            return raw.isEmpty ? Self.unnamedFallback : raw
        }
    }

    /// The brief a reader should actually use: this role's own `brief`, else the
    /// preset doctrine for what it does. nil means "no doctrine for this role";
    /// callers building a briefing fall back to a sentence of their own rather
    /// than inlining this chain. **The ONE spelling of resolution** — do not
    /// re-derive it at a call site.
    ///
    /// Only the designer has a preset brief in this plan. Translator preset
    /// briefs arrive with the briefing work; until then an un-briefed translator
    /// genuinely has none, and must not be handed the designer's.
    public var effectiveBrief: String? {
        if let brief, !brief.isEmpty { return brief }
        switch role {
        case .designer: return Self.designerBrief
        case .translator, .unknown: return nil
        }
    }

    // MARK: - The presets

    /// The designer every project has from the start — one per project, present
    /// before the writer has stored anything. `ProjectManifest.effectiveProductionRoles`
    /// prepends this whenever no stored role is a designer; it is never written
    /// back to disk on its own (tripwire 11: no migrations).
    public static let presetDesigner = ProductionRole(
        id: designerPresetID,
        role: .designer,
        name: designerName,
        brief: designerBrief)

    /// A **stable contract**, like the four preset pass ids: once a project has
    /// artifacts signed by this designer, renaming the id orphans them.
    public static let designerPresetID = "designer"

    /// The default name for a translator into `language`, or nil when the
    /// language has no preset — which is the case where the caller asks the
    /// writer who this person is, rather than manufacturing a name for them.
    ///
    /// Matching is on the lowercased tag; the table is deliberately small and
    /// exact — a regional tag (`es-MX`) is an unlisted language, and the writer
    /// naming their own translator is a better answer than a guess.
    public static func defaultTranslatorName(language: String) -> String? {
        presetTranslatorNames[language.lowercased()]
    }

    /// Real translators *into* each language — the spec fixes this table.
    private static let presetTranslatorNames: [String: String] = [
        "es": "Cortázar",
        "fr": "Baudelaire",
        "de": "Tieck",
        "ja": "Motoyuki",
    ]

    private static let designerName = "Tschichold"

    /// Reachable only through a degenerate value (an empty stored language tag,
    /// or an empty unknown raw). `effectiveName` promises never-empty; this is
    /// what keeps that promise honest.
    private static let unnamedFallback = "Unnamed"

    /// Tschichold designs the page rather than decorating it, and proves the
    /// spec on sample pages before anything reaches the live templates.
    private static let designerBrief = """
    Read the book's visual language statement before proposing anything — it is \
    the brief, not a starting point to improve on, and a design that contradicts \
    it is answering a question nobody asked. Design the page, not the \
    decoration: measure, leading, margins and the relation between them are \
    settled first, and ornament earns a place only once the page beneath it \
    works. Every proposal is one spec, stated in words and demonstrated in \
    sample pages, and it must account for every element the manuscript actually \
    contains — a verse passage, a block quote, a footnote or a slugline left \
    without a rule of its own is a hole in the design, not a detail for whoever \
    sets the book. Nothing reaches the live templates until the writer has seen \
    those samples and approved them.
    """
}
