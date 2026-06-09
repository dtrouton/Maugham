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

        public init(
            title: String = "Untitled",
            subtitle: String? = nil,
            author: String = "",
            copyright: String? = nil,
            isbn: String? = nil,
            publisher: String? = nil,
            year: Int? = nil,
            language: String = "en",
            keywords: [String] = []
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
        }

        enum CodingKeys: String, CodingKey {
            case title, subtitle, author, copyright, isbn
            case publisher, year, language, keywords
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

    public enum Format: String, Codable, Equatable, Sendable, CaseIterable {
        case pdf
        case epub

        /// Cross-version forward-tolerance (ADR 0015): an unknown output format
        /// from a newer build decodes to `.pdf` rather than throwing and making
        /// the whole `config.json` unloadable. `Format` lives in a
        /// `[Format]` array (`formats_enabled`), where one bad element would
        /// otherwise sink the entire `Outputs` block. `config.json` is Mac-only
        /// and already mostly `?? PublishConfig()`-guarded; this shores up the
        /// in-array case.
        public init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = Format(rawValue: raw) ?? .pdf
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

        public init(
            titleOverride: String? = nil,
            startOn: StartOn = .any,
            includeInToc: Bool = true,
            styleFile: String? = nil
        ) {
            self.titleOverride = titleOverride
            self.startOn = startOn
            self.includeInToc = includeInToc
            self.styleFile = styleFile
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encodeAlways(titleOverride, forKey: .titleOverride)
            try c.encode(startOn, forKey: .startOn)
            try c.encode(includeInToc, forKey: .includeInToc)
            try c.encodeAlways(styleFile, forKey: .styleFile)
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
        }

        enum CodingKeys: String, CodingKey {
            case titleOverride = "title_override"
            case startOn = "start_on"
            case includeInToc = "include_in_toc"
            case styleFile = "style_file"
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

    public init(
        schemaVersion: Int = 1,
        metadata: Metadata = .init(),
        outputs: Outputs = .init(),
        cover: Cover = .init(),
        sections: [String: Section] = [:],
        epubOverrides: EPUBOverrides = .init(),
        nextVersion: String = "0.1",
        activeLabelHint: String? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.metadata = metadata
        self.outputs = outputs
        self.cover = cover
        self.sections = sections
        self.epubOverrides = epubOverrides
        self.nextVersion = nextVersion
        self.activeLabelHint = activeLabelHint
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
    }
}
