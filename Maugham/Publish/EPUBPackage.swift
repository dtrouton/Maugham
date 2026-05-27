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
    }

    public struct Cover: Sendable {
        public let filename: String        // e.g. "cover.jpg"
        public let data: Data
        public let mediaType: String       // e.g. "image/jpeg"
    }

    public let metadata: Metadata
    public let sections: [Section]
    public let cover: Cover?
    public let stylesheetCSS: String

    public init(
        metadata: Metadata,
        sections: [Section],
        cover: Cover?,
        stylesheetCSS: String = ""
    ) {
        self.metadata = metadata
        self.sections = sections
        self.cover = cover
        self.stylesheetCSS = stylesheetCSS
    }
}
