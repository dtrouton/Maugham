import Foundation

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
    }

    public struct Cover: Codable, Equatable, Sendable {
        public var path: String?
        public var epubSpecificPath: String?

        public init(path: String? = "cover.jpg", epubSpecificPath: String? = nil) {
            self.path = path
            self.epubSpecificPath = epubSpecificPath
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

        public init(
            titleOverride: String? = nil,
            startOn: StartOn = .any,
            includeInToc: Bool = true
        ) {
            self.titleOverride = titleOverride
            self.startOn = startOn
            self.includeInToc = includeInToc
        }

        enum CodingKeys: String, CodingKey {
            case titleOverride = "title_override"
            case startOn = "start_on"
            case includeInToc = "include_in_toc"
        }
    }

    public enum StartOn: String, Codable, Equatable, Sendable {
        case any
        case recto
        case verso
    }

    public struct EPUBOverrides: Codable, Equatable, Sendable {
        public var metadata: [String: String]
        public var cover: String?

        public init(metadata: [String: String] = [:], cover: String? = nil) {
            self.metadata = metadata
            self.cover = cover
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
