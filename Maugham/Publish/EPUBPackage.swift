import Foundation

public struct EPUBPackage: Sendable {

    public struct Metadata: Sendable {
        public let title: String
        public let author: String
        public let subject: String?
        public let language: String
        public let isbn: String?
        public let identifier: String     // urn: form
        public let publisher: String?
        public let publishedYear: Int?
        public let keywords: [String]

        // Maugham-namespace metadata for round-trip.
        public let version: String
        public let label: String?
        public let checkpointID: String
        public let compiledAtISO8601: String

        public init(
            title: String,
            author: String,
            subject: String? = nil,
            language: String = "en",
            isbn: String? = nil,
            publisher: String? = nil,
            publishedYear: Int? = nil,
            keywords: [String] = [],
            version: String = "0.0",
            label: String? = nil,
            checkpointID: String = "",
            compiledAtISO8601: String = ISO8601DateFormatter().string(from: Date())
        ) {
            self.title = title
            self.author = author
            self.subject = subject
            self.language = language
            self.isbn = isbn
            self.publisher = publisher
            self.publishedYear = publishedYear
            self.keywords = keywords
            self.version = version
            self.label = label
            self.checkpointID = checkpointID
            self.compiledAtISO8601 = compiledAtISO8601

            if let isbn = isbn {
                self.identifier = "urn:isbn:\(isbn)"
            } else {
                let basis = "\(title)\u{0000}\(author)".data(using: .utf8) ?? Data()
                let uuid = UUID().uuidString.lowercased()  // good enough for v1
                _ = basis
                self.identifier = "urn:uuid:\(uuid)"
            }
        }
    }

    public struct Section: Sendable {
        public let id: String              // spine id, e.g. "s1"
        public let filename: String        // e.g. "section-001.xhtml"
        public let title: String
        public let xhtmlBody: String       // raw <section>...</section> from XHTMLBodyEmitter
        /// The language this section is written in — its body's `displayTag`
        /// (P2). Stamped on the section document's own `<html>` element, so
        /// each half of a bilingual book hyphenates and is spoken in its own
        /// language rather than in the publication's primary one.
        public let language: String
    }

    public struct Cover: Sendable {
        public let filename: String        // e.g. "cover.jpg"
        public let data: Data
        public let mediaType: String       // e.g. "image/jpeg"
    }

    /// A figure's image (report foundations plan 2, R-P2-7): packaged at
    /// `OEBPS/images/<filename>` with a manifest item and no spine entry. The
    /// bytes stay in `source` until the packager copies them file to file —
    /// never read into memory.
    public struct Image: Sendable, Equatable {
        /// `<sha256-prefix>.<ext>` — content-addressed, so one image used
        /// twice is one file.
        public let filename: String
        /// The resolved research file.
        public let source: URL
        public let mediaType: String       // e.g. "image/svg+xml"

        public init(filename: String, source: URL, mediaType: String) {
            self.filename = filename
            self.source = source
            self.mediaType = mediaType
        }

        /// Where the image sits in the archive, relative to `OEBPS/` — what a
        /// section's `<img src>` and the OPF item's `href` both say.
        public var href: String { "images/" + filename }
    }

    /// One entry of the nav's list of figures or tables (R-P2-6).
    public struct ListEntry: Sendable, Equatable {
        public let title: String           // "Figure 3. Revenue by quarter"
        public let href: String            // "section-002.xhtml#fig-3"

        public init(title: String, href: String) {
            self.title = title
            self.href = href
        }
    }

    public let metadata: Metadata
    public let sections: [Section]
    public let cover: Cover?
    public let stylesheetCSS: String
    /// One tag per rendered body, in order — what `<dc:language>` is emitted
    /// from. EPUB 3 permits several, and the FIRST is the publication's
    /// primary language.
    ///
    /// **Derived, never accepted whole**: the head is always
    /// `metadata.language`, because the rest of the metadata was folded to
    /// exactly one language and a primary `<dc:language>` naming a different
    /// one would be two answers to the same question. A caller supplies the
    /// ADDITIONAL bodies' tags; the head it passes is discarded.
    public let languages: [String]
    /// Every figure image, each filename once (first wins): a chart used in
    /// two chapters is one file and one manifest item.
    public let images: [Image]
    /// The nav's `epub:type="loi"` / `"lot"` entries; empty → no such nav.
    public let listOfFigures: [ListEntry]
    public let listOfTables: [ListEntry]

    public init(
        metadata: Metadata,
        sections: [Section],
        cover: Cover?,
        stylesheetCSS: String = "",
        languages: [String] = [],
        images: [Image] = [],
        listOfFigures: [ListEntry] = [],
        listOfTables: [ListEntry] = []
    ) {
        self.metadata = metadata
        self.sections = sections
        self.cover = cover
        self.stylesheetCSS = stylesheetCSS
        self.languages = [metadata.language] + languages.dropFirst()
        var seen = Set<String>()
        self.images = images.filter { seen.insert($0.filename).inserted }
        self.listOfFigures = listOfFigures
        self.listOfTables = listOfTables
    }
}
