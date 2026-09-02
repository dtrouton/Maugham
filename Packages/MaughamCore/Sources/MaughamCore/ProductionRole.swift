import Foundation

/// A named person in the project's publish department — a translator into one
/// language, that edition's blind reader and collator, or the book's designer
/// (the publish-department milestone).
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
        /// A blind reader of the finished edition: sees only the translation,
        /// never the original, and says where it does not sound like a book
        /// written in that language.
        case reader(language: String)
        /// Holds the original and the translation side by side and says where
        /// the two have drifted apart.
        case collator(language: String)
        case designer
        /// A role written by a newer build. Carries the original raw string so
        /// re-encode is lossless (see type doc).
        case unknown(String)

        private static let designerRaw = "designer"
        private static let translatorPrefix = "translator:"
        private static let readerPrefix = "reader:"
        private static let collatorPrefix = "collator:"

        /// The stable on-disk string (see type doc for the grammar).
        public var rawValue: String {
            switch self {
            case .designer: return Self.designerRaw
            case .translator(let language): return Self.translatorPrefix + language
            case .reader(let language): return Self.readerPrefix + language
            case .collator(let language): return Self.collatorPrefix + language
            case .unknown(let raw): return raw
            }
        }

        public init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            if raw == Self.designerRaw {
                self = .designer
            } else if let tag = Self.tag(of: raw, after: Self.translatorPrefix) {
                self = .translator(language: tag)
            } else if let tag = Self.tag(of: raw, after: Self.readerPrefix) {
                self = .reader(language: tag)
            } else if let tag = Self.tag(of: raw, after: Self.collatorPrefix) {
                self = .collator(language: tag)
            } else {
                self = .unknown(raw)
            }
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(rawValue)
        }

        /// The language tag after `prefix`, or nil when `raw` does not start
        /// with it **or the tag is empty** — an empty tag is the `.unknown`
        /// case, the type doc's rule, for all three language roles alike.
        private static func tag(of raw: String, after prefix: String) -> String? {
            guard raw.hasPrefix(prefix) else { return nil }
            let tag = String(raw.dropFirst(prefix.count))
            return tag.isEmpty ? nil : tag
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
            return Self.presetOrTag(Self.defaultTranslatorName(language: language), language)
        case .reader(let language):
            return Self.presetOrTag(Self.defaultReaderName(language: language), language)
        case .collator(let language):
            return Self.presetOrTag(Self.defaultCollatorName(language: language), language)
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
    /// The designer, the reader and the collator each have a preset doctrine.
    /// Translator preset briefs arrive with the briefing work; until then an
    /// un-briefed translator genuinely has none, and must not be handed anyone
    /// else's.
    public var effectiveBrief: String? {
        if let brief, !brief.isEmpty { return brief }
        switch role {
        case .designer: return Self.designerBrief
        case .reader: return Self.readerBrief
        case .collator: return Self.collatorBrief
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

    /// Real translators *into* each language — the spec fixes this table
    /// (§1; Serbian added 2026-09-02: Danilo Kiš, who translated Queneau,
    /// Tsvetaeva and Ady into Serbian).
    private static let presetTranslatorNames: [String: String] = [
        "es": "Cortázar",
        "fr": "Baudelaire",
        "de": "Tieck",
        "ja": "Motoyuki",
        "sr": "Kiš",
    ]

    private static let designerName = "Tschichold"

    /// Reachable only through a degenerate value (an empty stored language tag,
    /// or an empty unknown raw). `effectiveName` promises never-empty; this is
    /// what keeps that promise honest.
    private static let unnamedFallback = "Unnamed"

    /// The preset name, else the uppercased tag, else the never-empty fallback.
    private static func presetOrTag(_ preset: String?, _ language: String) -> String {
        if let preset { return preset }
        let tag = language.uppercased()
        return tag.isEmpty ? unnamedFallback : tag
    }

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

    /// Real readers of each language — the spec fixes this table (§1).
    public static func defaultReaderName(language: String) -> String? {
        presetReaderNames[language.lowercased()]
    }

    /// Writers who translated — the spec fixes this table (§1).
    public static func defaultCollatorName(language: String) -> String? {
        presetCollatorNames[language.lowercased()]
    }

    private static let presetReaderNames: [String: String] = [
        "es": "Ocampo", "fr": "Colette", "de": "Bachmann", "ja": "Enchi",
        "sr": "Sekulić",
    ]

    private static let presetCollatorNames: [String: String] = [
        "es": "Borges", "fr": "Yourcenar", "de": "Schlegel", "ja": "Futabatei",
        "sr": "Vinaver",
    ]

    /// The blind reader's doctrine (spec §1). It never names the language: the
    /// briefing's role frame does, so one doctrine serves every edition.
    private static let readerBrief = """
    You are reading a book written in the language of this edition. You have \
    not seen, and will not see, any other version of it. Say where it does not \
    sound like a book written in this language — a phrase no native writer \
    would reach for, register that wobbles, rhythm that limps, a name or idiom \
    transcribed rather than rendered. Judge against the edition brief's stated \
    register and its rulings, not a universal norm; a feature the brief declares \
    deliberate is not a fault. Write your notes and your report in the author's \
    language, which the briefing names. Do not rewrite. Do not guess what an \
    original might have said.
    """

    /// The collator's doctrine (spec §1).
    private static let collatorBrief = """
    You hold the original and the translation side by side. Say where the \
    translation departs from what the original says, and for each departure \
    whether it still says the same thing or has drifted — and render, \
    literally, into the author's language, what the translation now says \
    there, so the author can judge it. Deliberate repetition, sentence \
    architecture and the author's plainness are meaning: a synonym for a \
    repeated word is a departure. A directive on a paragraph is the standard \
    for that paragraph. Read the whole document against the glossary: a name \
    or term rendered two ways is a departure even when each paragraph is fine \
    alone. The translator's idiom is not your concern unless meaning moved.
    """
}
