import Foundation

// MARK: - Encoding helper

/// `encodeIfPresent` (Swift's default for `Optional`) omits nil fields,
/// which makes `config.json` shrink on every compile round-trip — the
/// starter ships explicit nulls for documentation purposes, and the
/// default encoder silently strips them. `encodeAlways` emits `null`
/// for nil so the file's shape stays stable across writes.
extension KeyedEncodingContainer {
    mutating func encodeAlways<T: Encodable>(
        _ value: T?, forKey key: Key
    ) throws {
        if let value {
            try encode(value, forKey: key)
        } else {
            try encodeNil(forKey: key)
        }
    }
}

/// Per-project publishing configuration. Persisted as
/// `.maugham/publish/config.json`. Small, schema-validated, MCP-mutable.
///
/// Anything aesthetic — fonts, page geometry, drop caps, custom commands —
/// lives in `template.tex` / `styles.css`, NOT here. The boundary protects
/// the differentiation: config can't drive the engine into generic output.
public struct PublishConfig: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var metadata: Metadata
    public var outputs: Outputs
    public var cover: Cover
    public var sections: [String: Section]   // keyed by piece_id
    public var epubOverrides: EPUBOverrides
    public var nextVersion: String           // e.g. "0.3"
    public var activeLabelHint: String?
    /// Per-language metadata overrides for translated editions, keyed by
    /// lowercase BCP-47-ish tag (e.g. "fr", "pt-br"). Empty for a
    /// single-language project. See `effectiveMetadata(language:)`.
    public var languageOverrides: [String: LanguageOverride]
    /// Named publishing configurations layered over the book-level config
    /// (spec §3), keyed by imprint name. Empty for a project with none.
    /// See `resolved(imprint:)`.
    public var imprints: [String: Imprint]
    /// Top-level template filename, replaced by an imprint's own `template`
    /// on resolution. `"template.tex"` by default.
    public var template: String
    /// The name of the imprint this config was `resolved(imprint:)` from.
    /// `nil` means the book. Set ONLY by `resolved(imprint:)` — never
    /// written directly.
    public var imprint: String?

    public struct Metadata: Codable, Equatable, Sendable {
        public var title: String
        public var subtitle: String?
        public var author: String
        public var copyright: String?
        public var isbn: String?
        public var publisher: String?
        public var year: Int?
        public var language: String
        public var keywords: [String]
        /// R-S16: the words this book's report elements print, each over the
        /// built-in word for `language` (`ElementWords.forBody`). Nil — the
        /// default — is the table's words throughout. A translated body sets
        /// its own through `language_overrides.<tag>.metadata`, flat, under
        /// the same keys (`effectiveMetadata(language:)`).
        public var elementWords: ElementWordsOverride?

        /// The title a config has before the writer names the book — the
        /// starter's `default-config.json` value and this init's default.
        public static let untitled = "Untitled"

        public init(
            title: String = Metadata.untitled,
            subtitle: String? = nil,
            author: String = "",
            copyright: String? = nil,
            isbn: String? = nil,
            publisher: String? = nil,
            year: Int? = nil,
            language: String = "en",
            keywords: [String] = [],
            elementWords: ElementWordsOverride? = nil
        ) {
            self.title = title
            self.subtitle = subtitle
            self.author = author
            self.copyright = copyright
            self.isbn = isbn
            self.publisher = publisher
            self.year = year
            self.language = language
            self.keywords = keywords
            self.elementWords = elementWords
        }

        // Custom encode: optional fields are emitted as explicit null
        // rather than omitted, so round-tripping config.json keeps shape.
        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(title, forKey: .title)
            try c.encodeAlways(subtitle, forKey: .subtitle)
            try c.encode(author, forKey: .author)
            try c.encodeAlways(copyright, forKey: .copyright)
            try c.encodeAlways(isbn, forKey: .isbn)
            try c.encodeAlways(publisher, forKey: .publisher)
            try c.encodeAlways(year, forKey: .year)
            try c.encode(language, forKey: .language)
            try c.encode(keywords, forKey: .keywords)
            try c.encodeAlways(elementWords, forKey: .elementWords)
        }

        enum CodingKeys: String, CodingKey {
            case title, subtitle, author, copyright, isbn
            case publisher, year, language, keywords
            case elementWords = "element_words"
        }
    }

    /// R-S16: `metadata.element_words` — each word a body's report elements
    /// print in place of the built-in one for its language. Every key is
    /// optional and a missing one keeps the built-in word; `keys` names them
    /// as they are spelled here and in a `language_overrides` entry.
    public struct ElementWordsOverride: Codable, Equatable, Sendable {
        public var figure: String?
        public var table: String?
        public var section: String?
        public var references: String?
        public var listOfFigures: String?
        public var listOfTables: String?
        /// A Word export label's two words (report plan 4, R-4-1).
        public var draft: String?
        public var sent: String?

        public init(figure: String? = nil, table: String? = nil, section: String? = nil,
                    references: String? = nil, listOfFigures: String? = nil,
                    listOfTables: String? = nil, draft: String? = nil, sent: String? = nil) {
            self.figure = figure
            self.table = table
            self.section = section
            self.references = references
            self.listOfFigures = listOfFigures
            self.listOfTables = listOfTables
            self.draft = draft
            self.sent = sent
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encodeAlways(figure, forKey: .figure)
            try c.encodeAlways(table, forKey: .table)
            try c.encodeAlways(section, forKey: .section)
            try c.encodeAlways(references, forKey: .references)
            try c.encodeAlways(listOfFigures, forKey: .listOfFigures)
            try c.encodeAlways(listOfTables, forKey: .listOfTables)
            try c.encodeAlways(draft, forKey: .draft)
            try c.encodeAlways(sent, forKey: .sent)
        }

        /// The one spelling of the keys, for `metadata.element_words` and for
        /// a `language_overrides` entry's flat metadata alike.
        enum CodingKeys: String, CodingKey, CaseIterable {
            case figure, table, section, references
            case listOfFigures = "list_of_figures"
            case listOfTables = "list_of_tables"
            case draft, sent
        }

        /// Sets the word a key names; false for a key that names none.
        mutating func set(_ key: String, to value: String) -> Bool {
            switch CodingKeys(rawValue: key) {
            case .figure?: figure = value
            case .table?: table = value
            case .section?: section = value
            case .references?: references = value
            case .listOfFigures?: listOfFigures = value
            case .listOfTables?: listOfTables = value
            case .draft?: draft = value
            case .sent?: sent = value
            case nil: return false
            }
            return true
        }
    }

    public struct Outputs: Codable, Equatable, Sendable {
        public var directory: String
        public var filenameTemplate: String
        public var sanitizeSpaces: Bool
        public var formatsEnabled: [Format]

        public init(
            directory: String = "Exports",
            filenameTemplate: String = "{title}-v{version}{label_suffix}.{ext}",
            sanitizeSpaces: Bool = false,
            formatsEnabled: [Format] = [.pdf, .epub]
        ) {
            self.directory = directory
            self.filenameTemplate = filenameTemplate
            self.sanitizeSpaces = sanitizeSpaces
            self.formatsEnabled = formatsEnabled
        }

        enum CodingKeys: String, CodingKey {
            case directory
            case filenameTemplate = "filename_template"
            case sanitizeSpaces = "sanitize_spaces"
            case formatsEnabled = "formats_enabled"
        }
    }

    /// An output format. `.pdf`, `.epub` and `.docx` (Word, report plan 4) are
    /// what this build can produce;
    /// `.unknown(raw)` is a format a NEWER build named, kept verbatim so it
    /// re-encodes as itself (ADR 0015 §5 amendment, pinned by
    /// `PublishFormatToleranceTests`). An unknown name in `formats_enabled` is
    /// not a config error — an older build can still edit a newer build's
    /// config — but compiling one is refused with `PublishFormatRefusal`.
    ///
    /// `allCases` is the formats this build can PRODUCE, so `.unknown` never
    /// reaches a picker. Deliberately NOT `RawRepresentable`: its stdlib
    /// `==`/hash compare `rawValue`, which would make `.unknown("pdf") == .pdf`;
    /// the synthesized ones compare cases.
    public enum Format: Codable, Equatable, Hashable, Sendable, CaseIterable {
        case pdf
        case epub
        case docx
        case unknown(String)

        public static var allCases: [Format] { [.pdf, .epub, .docx] }

        /// Non-failable. The known names match case-insensitively (a
        /// hand-typed `"PDF"`, `"Epub"` or `"DocX"` is the known format);
        /// anything else is `.unknown` with the original string kept verbatim.
        /// Never constructs `.unknown` around a known name.
        public init(rawValue: String) {
            switch rawValue.lowercased() {
            case "pdf":  self = .pdf
            case "epub": self = .epub
            case "docx": self = .docx
            default:     self = .unknown(rawValue)
            }
        }

        public var rawValue: String {
            switch self {
            case .pdf:              return "pdf"
            case .epub:             return "epub"
            case .docx:             return "docx"
            case .unknown(let raw): return raw
            }
        }

        /// A Word export is a draft, not a version (R-4-1): it mints
        /// `draft-N` (`WordDraft`) and never reads or moves `next_version`.
        public var mintsDrafts: Bool {
            switch self {
            case .docx: return true
            case .pdf, .epub, .unknown: return false
            }
        }

        public init(from decoder: Decoder) throws {
            self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.singleValueContainer()
            try c.encode(rawValue)
        }
    }

    public struct Cover: Codable, Equatable, Sendable {
        public var path: String?
        public var epubSpecificPath: String?

        public init(path: String? = "cover.jpg", epubSpecificPath: String? = nil) {
            self.path = path
            self.epubSpecificPath = epubSpecificPath
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encodeAlways(path, forKey: .path)
            try c.encodeAlways(epubSpecificPath, forKey: .epubSpecificPath)
        }

        enum CodingKeys: String, CodingKey {
            case path
            case epubSpecificPath = "epub_specific_path"
        }
    }

    public struct Section: Codable, Equatable, Sendable {
        public var titleOverride: String?
        public var startOn: StartOn
        public var includeInToc: Bool
        public var styleFile: String?
        /// F1: when `false`, this piece is excluded from the compiled edition —
        /// not emitted (both formats), not gated by translation coverage, and
        /// dropped from `preview_compile`'s default (no-`section_ids`) subset.
        /// Default `true` (absent ⇒ included, ADR 0015 additive-optional).
        public var include: Bool

        public init(
            titleOverride: String? = nil,
            startOn: StartOn = .any,
            includeInToc: Bool = true,
            styleFile: String? = nil,
            include: Bool = true
        ) {
            self.titleOverride = titleOverride
            self.startOn = startOn
            self.includeInToc = includeInToc
            self.styleFile = styleFile
            self.include = include
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encodeAlways(titleOverride, forKey: .titleOverride)
            try c.encode(startOn, forKey: .startOn)
            try c.encode(includeInToc, forKey: .includeInToc)
            try c.encodeAlways(styleFile, forKey: .styleFile)
            try c.encode(include, forKey: .include)
        }

        // Custom decode so a PARTIAL section survives RFC-7396 merge-patch.
        // `set_publish_config` merges the patch into the config JSON, then
        // decodes the whole `PublishConfig`. A first-time per-section override
        // (e.g. `{"sections":{"ab12":{"title_override":"X"}}}`) merges into a
        // section object that has ONLY that one key — the synthesized decoder
        // would then throw `keyNotFound` for the non-optional `start_on` /
        // `include_in_toc`. Defaulting missing fields here is what makes a
        // partial section patch behave per the merge-patch contract.
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.titleOverride = try c.decodeIfPresent(String.self, forKey: .titleOverride)
            self.startOn = try c.decodeIfPresent(StartOn.self, forKey: .startOn) ?? .any
            self.includeInToc = try c.decodeIfPresent(Bool.self, forKey: .includeInToc) ?? true
            self.styleFile = try c.decodeIfPresent(String.self, forKey: .styleFile)
            self.include = try c.decodeIfPresent(Bool.self, forKey: .include) ?? true
        }

        enum CodingKeys: String, CodingKey {
            case titleOverride = "title_override"
            case startOn = "start_on"
            case includeInToc = "include_in_toc"
            case styleFile = "style_file"
            case include
        }
    }

    public enum StartOn: String, Codable, Equatable, Sendable {
        case any
        case recto
        case verso

        /// Cross-version forward-tolerance (ADR 0015): an unknown page-parity
        /// value from a newer build decodes to `.any` (the no-constraint
        /// default) rather than throwing. `Section.init(from:)` already defaults
        /// a *missing* key to `.any`; this covers a *present-but-unknown* value.
        public init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = StartOn(rawValue: raw) ?? .any
        }
    }

    public struct EPUBOverrides: Codable, Equatable, Sendable {
        public var metadata: [String: String]
        public var cover: String?

        public init(metadata: [String: String] = [:], cover: String? = nil) {
            self.metadata = metadata
            self.cover = cover
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(metadata, forKey: .metadata)
            try c.encodeAlways(cover, forKey: .cover)
        }

        enum CodingKeys: String, CodingKey {
            case metadata, cover
        }
    }

    /// Metadata overrides for one translated edition. Mirrors `EPUBOverrides`'
    /// free-form `metadata` dict: known keys (`title`, `author`, `year`, …) are
    /// applied by `effectiveMetadata(language:)`; unknown keys are ignored.
    public struct LanguageOverride: Codable, Equatable, Sendable {
        public var metadata: [String: String]

        public init(metadata: [String: String] = [:]) {
            self.metadata = metadata
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(metadata, forKey: .metadata)
        }

        enum CodingKeys: String, CodingKey {
            case metadata
        }
    }

    /// A named publishing configuration layered over the book-level config
    /// (spec §3). `resolved(imprint:)` applies it: `template` replaces;
    /// `sections`, when present, is an ALLOWLIST (absent means inherit the
    /// project's map); `metadata`/`outputs`/`cover` are RFC 7396 merge-patch
    /// fragments (`null` deletes); `nextVersion` is the imprint's own counter.
    public struct Imprint: Codable, Equatable, Sendable {
        public var template: String?
        public var sections: [String: Section]?
        public var metadata: [String: JSONValue]?
        public var outputs: [String: JSONValue]?
        public var cover: [String: JSONValue]?
        public var nextVersion: String?

        public init(
            template: String? = nil,
            sections: [String: Section]? = nil,
            metadata: [String: JSONValue]? = nil,
            outputs: [String: JSONValue]? = nil,
            cover: [String: JSONValue]? = nil,
            nextVersion: String? = nil
        ) {
            self.template = template
            self.sections = sections
            self.metadata = metadata
            self.outputs = outputs
            self.cover = cover
            self.nextVersion = nextVersion
        }

        enum CodingKeys: String, CodingKey {
            case template, sections, metadata, outputs, cover
            case nextVersion = "next_version"
        }
    }

    public init(
        schemaVersion: Int = 1,
        metadata: Metadata = .init(),
        outputs: Outputs = .init(),
        cover: Cover = .init(),
        sections: [String: Section] = [:],
        epubOverrides: EPUBOverrides = .init(),
        nextVersion: String = "0.1",
        activeLabelHint: String? = nil,
        languageOverrides: [String: LanguageOverride] = [:],
        imprints: [String: Imprint] = [:],
        template: String = "template.tex",
        imprint: String? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.metadata = metadata
        self.outputs = outputs
        self.cover = cover
        self.sections = sections
        self.epubOverrides = epubOverrides
        self.nextVersion = nextVersion
        self.activeLabelHint = activeLabelHint
        self.languageOverrides = languageOverrides
        self.imprints = imprints
        self.template = template
        self.imprint = imprint
    }

    /// F1: the piece ids whose section carries `include == false`. These are
    /// dropped from the emitted edition, excluded from the translation coverage
    /// gate, and subtracted from `preview_compile`'s default subset. A piece
    /// with no section entry defaults to included, so it never appears here.
    public var excludedSectionIDs: Set<String> {
        Set(sections.filter { !$0.value.include }.keys)
    }

    /// The metadata that should drive an edition compiled for `language`.
    ///
    /// - `language == nil`: the base `metadata`, unchanged (single-language
    ///   compile).
    /// - otherwise: `metadata` with its `language` set to the tag (dc:language),
    ///   then the `languageOverrides[language]` dict applied over the known keys.
    ///   An explicit `language` key in the override dict wins over the raw tag.
    ///   R-S16: the book's `element_words` are in the book's language, so a
    ///   body in another language drops them; the override dict's
    ///   `ElementWordsOverride` keys (`figure`, `list_of_tables`, …) set that
    ///   body's own.
    public func effectiveMetadata(language: String?) -> Metadata {
        guard let language else { return metadata }
        var m = metadata
        m.language = language
        let override = languageOverrides[language]?.metadata ?? [:]
        if let v = override["language"] { m.language = v }
        if m.language != metadata.language { m.elementWords = nil }
        for (key, value) in override {
            var words = m.elementWords ?? ElementWordsOverride()
            if words.set(key, to: value) { m.elementWords = words }
        }
        if let v = override["title"]     { m.title = v }
        if let v = override["subtitle"]  { m.subtitle = v }
        if let v = override["author"]    { m.author = v }
        if let v = override["copyright"] { m.copyright = v }
        if let v = override["isbn"]      { m.isbn = v }
        if let v = override["publisher"] { m.publisher = v }
        if let v = override["year"], let y = Int(v) { m.year = y }  // unparseable ignored
        if let v = override["keywords"] {
            m.keywords = v.split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        }
        return m
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(schemaVersion, forKey: .schemaVersion)
        try c.encode(metadata, forKey: .metadata)
        try c.encode(outputs, forKey: .outputs)
        try c.encode(cover, forKey: .cover)
        try c.encode(sections, forKey: .sections)
        try c.encode(epubOverrides, forKey: .epubOverrides)
        try c.encode(nextVersion, forKey: .nextVersion)
        try c.encodeAlways(activeLabelHint, forKey: .activeLabelHint)
        try c.encode(languageOverrides, forKey: .languageOverrides)
        if !imprints.isEmpty {
            try c.encode(imprints, forKey: .imprints)
        }
        if template != "template.tex" {
            try c.encode(template, forKey: .template)
        }
        try c.encodeIfPresent(imprint, forKey: .imprint)
    }

    // Explicit top-level decoder: the synthesized `init(from:)` would throw
    // `keyNotFound` on `language_overrides` for any config.json written before
    // this milestone (Swift does not honor a stored-property default during
    // synthesized decode). Every pre-existing key is decoded exactly as the
    // synthesized decoder would (required = `decode`, optional = `decodeIfPresent`);
    // only `language_overrides` is tolerated-missing → `[:]`.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
        metadata = try c.decode(Metadata.self, forKey: .metadata)
        outputs = try c.decode(Outputs.self, forKey: .outputs)
        cover = try c.decode(Cover.self, forKey: .cover)
        sections = try c.decode([String: Section].self, forKey: .sections)
        epubOverrides = try c.decode(EPUBOverrides.self, forKey: .epubOverrides)
        nextVersion = try c.decode(String.self, forKey: .nextVersion)
        activeLabelHint = try c.decodeIfPresent(String.self, forKey: .activeLabelHint)
        languageOverrides = try c.decodeIfPresent(
            [String: LanguageOverride].self, forKey: .languageOverrides) ?? [:]
        imprints = try c.decodeIfPresent([String: Imprint].self, forKey: .imprints) ?? [:]
        template = try c.decodeIfPresent(String.self, forKey: .template) ?? "template.tex"
        imprint = try c.decodeIfPresent(String.self, forKey: .imprint)
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case metadata
        case outputs
        case cover
        case sections
        case epubOverrides = "epub_overrides"
        case nextVersion = "next_version"
        case activeLabelHint = "active_label_hint"
        case languageOverrides = "language_overrides"
        case imprints
        case template
        case imprint
    }
}

/// **The one refusal for compiling an output format this build can't
/// produce** (`PublishConfig.Format.unknown`). `message(raw:)` is the one
/// sentence: any error type that carries it calls this rather than restating
/// it. Thrown by the three dispatch switches (`PublishOrchestrator`,
/// `Republisher`, `PreviewCompiler`) as defence in depth behind the compile
/// doors.
public struct PublishFormatRefusal: Error, LocalizedError, Equatable, Sendable {
    /// The format's name exactly as the config or catalog spelled it.
    public let raw: String

    public init(raw: String) { self.raw = raw }

    public static func message(raw: String) -> String {
        "This Maugham can't produce '\(raw)' output — it was named by a newer "
            + "version of Maugham. Update Maugham to compile it. Nothing was compiled."
    }

    public var errorDescription: String? { Self.message(raw: raw) }
}
